# frozen_string_literal: true

module MissionControlDashboard
  # A log that can never stall the thing it is logging about.
  #
  # This exists because of a real hang. Every request used to `warn` straight
  # to stderr from the request-serving thread, *before* writing the response.
  # Writing to a console is not guaranteed to be fast:
  #
  #   - On Windows, clicking inside the console window enables Quick Edit
  #     selection, and Windows suspends every write to that console until you
  #     press Esc. The process is not paused; only its output is.
  #   - On any OS, redirecting output to a pipe nobody reads blocks once the
  #     64KB buffer fills.
  #
  # In both cases the server stayed alive and kept accepting TCP connections
  # while answering none of them — a hang that looks exactly like a dead
  # server but reports as healthy.
  #
  # So: request threads only ever push onto a bounded queue and move on. One
  # writer thread does the blocking part. If the console stops draining, that
  # thread stalls alone, the queue fills, and lines are DROPPED. Losing log
  # lines is always better than losing the dashboard.
  class SafeLogger
    MAX_QUEUE = 512

    def initialize(io = $stderr, enabled: true)
      @io = io
      @enabled = enabled
      @queue = Queue.new
      @dropped = 0
      @mutex = Mutex.new
      @thread = start_writer if enabled
    end

    def dropped
      @mutex.synchronize { @dropped }
    end

    def write(message)
      return unless @enabled

      # Queue#size is a cheap read; the race here is benign — worst case we
      # allow one extra line or drop one we could have kept.
      if @queue.size >= MAX_QUEUE
        @mutex.synchronize { @dropped += 1 }
        return
      end
      @queue << "[#{Time.now.strftime('%H:%M:%S')}] #{message}\n"
      nil
    end
    alias << write

    def close
      return unless @thread

      @queue << :stop
      @thread.join(1)
      @thread = nil
    end

    private

    def start_writer
      Thread.new do
        loop do
          item = @queue.pop
          break if item == :stop

          note = @mutex.synchronize do
            next nil if @dropped.zero?

            n = @dropped
            @dropped = 0
            "[log] #{n} message#{'s' if n != 1} dropped while output was blocked " \
            "(on Windows: click in the console + Quick Edit pauses output; press Esc)\n"
          end

          begin
            # Only this thread is allowed to block here.
            @io.write(note) if note
            @io.write(item)
            @io.flush if @io.respond_to?(:flush)
          rescue StandardError
            # A broken pipe or closed console must not kill the writer.
            nil
          end
        end
      rescue StandardError
        nil
      end
    end
  end
end
