module Accomplice
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}

  module Windows
    module Service
      DEFAULT_SHUTDOWN_TIMEOUT = 5.seconds
      DEFAULT_WAIT_HINT        = 5.seconds

      @@shutdown_timeout = DEFAULT_SHUTDOWN_TIMEOUT
      @@status : Atomic(LibWindowsService::SERVICE_STATUS_CURRENT_STATE) = Atomic.new(LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOPPED)
      @@status_handle : LibWindowsService::SERVICE_STATUS_HANDLE?
      @@status_mutex = Mutex.new(Mutex::Protection::Reentrant)
      @@connection_channel = Channel(Tuple(Bool, Exception?)).new

      # Sets the time waited for graceful shutdown before stopping the
      # service and forcibly exiting the process
      def self.shutdown_timeout=(@@shutdown_timeout : Time::Span)
      end

      # Handles controls sent from the Windows Service Manager to
      # manage the service, called by the dispatcher
      # Only stop and shutdown controls are handled
      protected def self.manage(control : LibC::DWORD) : Nil
        case control
        when LibWindowsService::SERVICE_CONTROL_STOP, LibWindowsService::SERVICE_CONTROL_SHUTDOWN
          set_status(@@status_handle, LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOP_PENDING)
          # send CTRL+C (SIGINT) signal to request graceful shutdown
          # and process exit
          if LibWindowsService.GenerateConsoleCtrlEvent(0, 0) == 0
            raise "WINDOWS SERVICE CONTROL HANDLER FAILED: `GenerateConsoleCtrlEvent(0, 0)` => #{WinError.value.to_i} #{WinError.value.to_s}: #{WinError.value.message}"
          end
          # wait on a dedicated thread for a graceful shutdown within
          # configured timeout period, otherwise stop the service and
          # forcibly exit the process
          Fiber::ExecutionContext::Isolated.new("WINDOWS SERVICE SHUTDOWN") do
            sleep @@shutdown_timeout
            shutdown(1, nil)
            Process.exit
          end
        end
      end

      # Performs shutdown tasks before stopping the Windows Service
      protected def self.shutdown(status : Int32, exception : Exception?) : Nil
        LibWindowsService.FreeConsole if @@console_allocated
        set_status(@@status_handle, LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOPPED) if exception.nil?
      end

      # The Windows Service main logic
      protected def self.main(argc : LibC::DWORD, argv : Pointer(Pointer(UInt8))) : Nil
        # IMPORTANT: some methods such as `Log` methods do not work
        # within this execution context (raw thread started by the
        # Windows Service Control Manager dispatcher). Therefore we
        # start a new execution context to ensure everything works as
        # expected when starting the service.
        Fiber::ExecutionContext::Isolated.new("WINDOWS SERVICE MAIN") do
          # treat windows service arguments as if they were console
          # arguments
          ARGV.clear
          argv.to_slice(argc).each do |chars|
            ARGV << String.new(chars)
          end

          return_value = LibWindowsService.RegisterServiceCtrlHandlerA("", ->Windows::Service.manage(LibC::DWORD))
          raise "WINDOWS SERVICE MAIN CONTROL HANDLER REGISTRATION FAILED: `LibWindowsService.RegisterServiceCtrlHandlerA(...)` => #{WinError.value.to_i} #{WinError.value.to_s}: #{WinError.value.message}" if return_value == 0

          @@status_handle = return_value
          @@console_allocated = LibWindowsService.AllocConsole != 0

          # stop the windows service when the process exits
          at_exit do |status, exception|
            shutdown(status, exception)
          end

          set_status(@@status_handle, LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING)
          set_status(@@status_handle, LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_RUNNING)

          @@connection_channel.send({true, nil})
        rescue ex
          @@connection_channel.send({false, ex})
        end
      end

      # Registers the program as a Windows Service
      def self.register
        # run the service dispatcher in its own isolated thread as the
        # call to `StartServiceCtrlDispatcherA` is blocking, and will
        # not exit until the service is stopped
        Fiber::ExecutionContext::Isolated.new("WINDOWS SERVICE DISPATCHER") do
          services = uninitialized LibWindowsService::SERVICE_TABLE_ENTRYA[2]
          services[0] = LibWindowsService::SERVICE_TABLE_ENTRYA.new(service_name: "", service_main_function: ->Windows::Service.main(LibC::DWORD, Pointer(Pointer(UInt8))))
          services[1] = LibWindowsService::SERVICE_TABLE_ENTRYA.new(service_name: nil, service_main_function: nil)

          if LibWindowsService.StartServiceCtrlDispatcherA(services.to_unsafe) == 0
            if WinError.value == WinError::ERROR_FAILED_SERVICE_CONTROLLER_CONNECT
              # this is an expected state when running the program as
              # a console application rather than windows service
              @@connection_channel.send({false, nil})
            else
              raise "WINDOWS SERVICE DISPATCHER REGISTRATION FAILED: `StartServiceCtrlDispatcherA(...)` => #{WinError.value.to_i} #{WinError.value.to_s}: #{WinError.value.message}"
            end
          end
        rescue ex
          @@connection_channel.send({false, ex})
        end

        # wait for service dispatcher and service main to connect to
        # the service control manager, then if connected register
        # default interrupt signal handler to exit the program, if not
        # connected then the program is not running as a windows
        # service and is responsible for it's own handling of signals
        connected, exception = @@connection_channel.receive
        if exception
          raise exception
        elsif connected
          # default interrupt signal handler to exit gracefully with
          # at_exit callbacks called
          Process.on_terminate do |reason|
            exit
          end
        end
      end

      # Registers the given *status* against the service with the
      # service control manager
      protected def self.set_status(status_handle : LibWindowsService::SERVICE_STATUS_HANDLE?, status : LibWindowsService::SERVICE_STATUS_CURRENT_STATE) : Nil
        @@status_mutex.synchronize do
          if handle = status_handle
            service_status = LibWindowsService::SERVICE_STATUS.new
            service_status.service_type = LibWindowsService::ENUM_SERVICE_TYPE::SERVICE_WIN32_OWN_PROCESS
            service_status.current_state = status
            service_status.win32_exit_code = WinError::ERROR_SUCCESS
            service_status.service_specific_exit_code = 0
            service_status.check_point = 0

            if service_status.current_state == LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_STOP_PENDING
              service_status.wait_hint = @@shutdown_timeout.total_milliseconds.to_i
            else
              service_status.wait_hint = DEFAULT_WAIT_HINT.total_milliseconds.to_i
            end

            if service_status.current_state == LibWindowsService::SERVICE_STATUS_CURRENT_STATE::SERVICE_START_PENDING
              service_status.controls_accepted = 0
            else
              service_status.controls_accepted = LibWindowsService::SERVICE_ACCEPT_SHUTDOWN | LibWindowsService::SERVICE_ACCEPT_STOP
            end

            if LibWindowsService.SetServiceStatus(handle, pointerof(service_status)) == 0
              raise "WINDOWS SERVICE SET STATUS FAILED: `SetServiceStatus(#{handle}, #{service_status})` => #{WinError.value.to_i} #{WinError.value.to_s}: #{WinError.value.message}"
            else
              @@status.set status
            end
          else
            raise "status_handle must not be nil"
          end
        end
      end

      @[Link("advapi32")]
      @[Link("kernel32")]
      lib LibWindowsService
        alias PSTR = UInt8*
        alias SERVICE_STATUS_HANDLE = LibC::IntPtrT
        alias LPSERVICE_MAIN_FUNCTIONW = Proc(UInt32, LibC::LPWSTR*, Void)
        alias LPSERVICE_MAIN_FUNCTIONA = Proc(UInt32, PSTR*, Void)
        alias LPHANDLER_FUNCTION = Proc(UInt32, Void)
        alias LPHANDLER_FUNCTION_EX = Proc(UInt32, UInt32, Void*, Void*, UInt32)

        SERVICE_NO_CHANGE                     = 4294967295_u32
        SERVICE_CONTROL_STOP                  =          1_u32
        SERVICE_CONTROL_PAUSE                 =          2_u32
        SERVICE_CONTROL_CONTINUE              =          3_u32
        SERVICE_CONTROL_INTERROGATE           =          4_u32
        SERVICE_CONTROL_SHUTDOWN              =          5_u32
        SERVICE_CONTROL_PARAMCHANGE           =          6_u32
        SERVICE_CONTROL_NETBINDADD            =          7_u32
        SERVICE_CONTROL_NETBINDREMOVE         =          8_u32
        SERVICE_CONTROL_NETBINDENABLE         =          9_u32
        SERVICE_CONTROL_NETBINDDISABLE        =         10_u32
        SERVICE_CONTROL_DEVICEEVENT           =         11_u32
        SERVICE_CONTROL_HARDWAREPROFILECHANGE =         12_u32
        SERVICE_CONTROL_POWEREVENT            =         13_u32
        SERVICE_CONTROL_SESSIONCHANGE         =         14_u32
        SERVICE_CONTROL_PRESHUTDOWN           =         15_u32
        SERVICE_CONTROL_TIMECHANGE            =         16_u32
        SERVICE_CONTROL_TRIGGEREVENT          =         32_u32
        SERVICE_CONTROL_LOWRESOURCES          =         96_u32
        SERVICE_CONTROL_SYSTEMLOWRESOURCES    =         97_u32
        SERVICE_ACCEPT_STOP                   =          1_u32
        SERVICE_ACCEPT_PAUSE_CONTINUE         =          2_u32
        SERVICE_ACCEPT_SHUTDOWN               =          4_u32
        SERVICE_ACCEPT_PARAMCHANGE            =          8_u32
        SERVICE_ACCEPT_NETBINDCHANGE          =         16_u32
        SERVICE_ACCEPT_HARDWAREPROFILECHANGE  =         32_u32
        SERVICE_ACCEPT_POWEREVENT             =         64_u32
        SERVICE_ACCEPT_SESSIONCHANGE          =        128_u32
        SERVICE_ACCEPT_PRESHUTDOWN            =        256_u32
        SERVICE_ACCEPT_TIMECHANGE             =        512_u32
        SERVICE_ACCEPT_TRIGGEREVENT           =       1024_u32
        SERVICE_ACCEPT_USER_LOGOFF            =       2048_u32
        SERVICE_ACCEPT_LOWRESOURCES           =       8192_u32
        SERVICE_ACCEPT_SYSTEMLOWRESOURCES     =      16384_u32

        enum ENUM_SERVICE_TYPE : UInt32
          SERVICE_DRIVER              = 11
          SERVICE_FILE_SYSTEM_DRIVER_ =  2
          SERVICE_KERNEL_DRIVER       =  1
          SERVICE_WIN32               = 48
          SERVICE_WIN32_OWN_PROCESS_  = 16
          SERVICE_WIN32_SHARE_PROCESS = 32
          SERVICE_ADAPTER             =  4
          SERVICE_FILE_SYSTEM_DRIVER  =  2
          SERVICE_RECOGNIZER_DRIVER   =  8
          SERVICE_WIN32_OWN_PROCESS   = 16
          SERVICE_USER_OWN_PROCESS    = 80
          SERVICE_USER_SHARE_PROCESS  = 96
        end

        enum SERVICE_STATUS_CURRENT_STATE : UInt32
          SERVICE_CONTINUE_PENDING = 5
          SERVICE_PAUSE_PENDING    = 6
          SERVICE_PAUSED           = 7
          SERVICE_RUNNING          = 4
          SERVICE_START_PENDING    = 2
          SERVICE_STOP_PENDING     = 3
          SERVICE_STOPPED          = 1
        end

        struct SERVICE_TABLE_ENTRYA
          service_name : PSTR
          service_main_function : LPSERVICE_MAIN_FUNCTIONA
        end

        struct SERVICE_TABLE_ENTRYW
          service_name : LibC::LPWSTR
          service_main_function : LPSERVICE_MAIN_FUNCTIONW
        end

        struct SERVICE_STATUS
          service_type : ENUM_SERVICE_TYPE
          current_state : SERVICE_STATUS_CURRENT_STATE
          controls_accepted : UInt32
          win32_exit_code : UInt32
          service_specific_exit_code : UInt32
          check_point : UInt32
          wait_hint : UInt32
        end

        fun AllocConsole : LibC::BOOL
        fun FreeConsole : LibC::BOOL
        fun GenerateConsoleCtrlEvent(control_event : LibC::DWORD, process_group_id : LibC::DWORD) : LibC::BOOL
        fun RegisterServiceCtrlHandlerA(service_name : PSTR, handler_function : LPHANDLER_FUNCTION) : SERVICE_STATUS_HANDLE
        fun RegisterServiceCtrlHandlerW(service_name : LibC::LPWSTR, handler_function : LPHANDLER_FUNCTION) : SERVICE_STATUS_HANDLE
        fun SetServiceStatus(service_status_handle : SERVICE_STATUS_HANDLE, service_status : SERVICE_STATUS*) : LibC::BOOL
        fun StartServiceCtrlDispatcherA(service_table : SERVICE_TABLE_ENTRYA*) : LibC::BOOL
        fun StartServiceCtrlDispatcherW(service_table : SERVICE_TABLE_ENTRYW*) : LibC::BOOL
      end
    end
  end
end

{% if flag?(:win32) %}
  Accomplice::Windows::Service.register
{% end %}
