# Accomplice

Allows any Crystal language program to easily run as a Windows Service
with minimal change, while continuing to support running as a console
application also.

Handles the Windows Service API for you. Adding Windows Service
support is as simple as adding the dependency on Accomplice to your
`shard.yml` file, and including a `require "accomplice"` line in your
program.

Should you wish to add support for graceful shutdown, doing so
requires minimal additional effort, either:
* Add `at_exit` handlers to perform graceful shutdown tasks, or
* Use `Process.on_terminate` to register your own interrupt signal
  handler to perform graceful shutdown tasks and then `exit`.

By default Accomplice waits 5 seconds for your program to gracefully
shutdown, after which it forcibly stops the process.

You can also continue to run your program manually via the console
after the above changes, without interference from Accomplice or the
Windows Service API.

## Usage

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     accomplice:
       github: lachlan/crystal-accomplice
   ```

2. Run `shards install`

3. Require `accomplice` in your program, and then optionally include
   logic to gracefully shutdown your program when interrupted:

```crystal
# Accomplice handles the Windows Service API for you, so that your
# program can be started and stopped by the Windows Service Control
# Manager (SCM).
#
# When you `require "accomplice"`, if the program was started by SCM
# then Accomplice will register the program as a Windows Service with
# SCM and set the status of the service to running.
#
# Otherwise if the program was started normally as a console
# application, Accomplice has no effect and your program runs normally
# as it always has before.

require "accomplice"

# Accomplice converts Windows Service Control Manager stop/shutdown
# controls to CTRL+C (SIGINT) interrupt signals to request the program
# to stop.
#
# Accomplice also includes a default interrupt signal handler which
# calls `exit`, allowing `at_exit` handlers to be used to gracefully
# shutdown:

at_exit {
  # ...perform graceful shutdown tasks...
}

# OR you can replace the default interrupt signal handler with your
# own by using `Process.on_terminate` with a handler that stops your
# program gracefully and then exits:

Process.on_terminate do |reason|
  Log.info { "SHUTDOWN INITIATED BY PROCESS TERMINATION, REASON = #{reason}" }
  # ...perform graceful shutdown tasks...
  exit
end

# Then run your program's logic as per normal:
loop do
  # ...do stuff...
  sleep 1.second
end

```

4. Compile: `shards build -Dpreview_mt -Dexecution_context`

   A Windows Service necessarily requires at least two (2) threads:
   * the service dispatcher thread, and
   * at least one other thread to run the actual service logic.

   This requires compiling your Crystal program with the following
   flags:
   * `-Dpreview_mt` to enable multithreading, and
   * `-Dexecution_context` to enable the new execution contexts.

5. Create Windows service (note: these commands need to be run as an
   Administrator):

```bat
sc create <ServiceName> binpath= <ExecutablePath>
sc config <ServiceName> start= <boot|system|auto|demand|disabled|delayed-auto>
sc config <ServiceName> DisplayName= "<Service Display Name>"
sc description <ServiceName> "<Service Description>"
```

6. Run Windows service

```bat
sc start <ServiceName>
...
sc stop <ServiceName>
```

## Contributing

1. Fork it (<https://github.com/lachlan/crystal-accomplice/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Lachlan Dowding](https://github.com/lachlan) - creator and maintainer
