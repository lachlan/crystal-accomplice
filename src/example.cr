require "log"

Log.setup_from_env(backend: Log::IOBackend.new(File.new(File.join(File.dirname(Process.executable_path.not_nil!), File.basename(Process.executable_path.not_nil!) + ".log"), "a")))

require "./accomplice"

running = true
at_exit do |status, exception|
  running = false
  sleep 1.second
end

Log.info { "RUN LOOP STARTED" }

i = 1
while running
  Log.info { "RUN LOOP ITERATION: #{i}" }
  i += 1
  sleep 1.second
end

Log.info { "RUN LOOP ENDED" }
