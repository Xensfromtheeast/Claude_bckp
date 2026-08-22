# frozen_string_literal: true

require "socket"
require "uri"

require_relative "logger"

module MissionControlDashboard
  # A small threaded HTTP/1.1 server built on stdlib sockets.
  #
  # Why not Sinatra + Puma + Rack? Because this dashboard has a handful of
  # routes and no middleware. Three gems, each with their own version
  # constraints, is the entire reason the previous build kept failing to
  # install. Ruby's stdlib already ships everything a localhost dashboard
  # needs.
  #
  # What it does need, and what a naive version gets wrong:
  #   - logging that cannot block the response (see SafeLogger)
  #   - a deadline on every read, so a client that connects and says nothing
  #     cannot pin a thread and a file descriptor forever
  #   - a ceiling on concurrent connections, shedding load rather than
  #     exhausting the process
  #   - an accept loop that survives every error it can survive
  class HTTPServer
    STATUS = {
      200 => "OK", 201 => "Created", 204 => "No Content", 400 => "Bad Request",
      403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed",
      408 => "Request Timeout", 409 => "Conflict", 413 => "Payload Too Large",
      422 => "Unprocessable Entity", 500 => "Internal Server Error",
      503 => "Service Unavailable"
    }.freeze

    MAX_REQUEST_LINE = 8192
    MAX_BODY         = 512 * 1024
    MAX_HEADERS      = 64
    MAX_CONNECTIONS  = 64
    IDLE_TIMEOUT     = 15   # a client gets this long to send its request
    WRITE_TIMEOUT    = 15

    def initialize(app, host: "127.0.0.1", port: 4567, quiet: false, logger: nil)
      @app = app
      @host = host
      @port = port
      @log = logger || SafeLogger.new($stderr, enabled: !quiet)
      @running = false
      @active = 0
      @served = 0
      @shed = 0
      @lock = Mutex.new
    end

    def stats
      @lock.synchronize do
        { "active" => @active, "served" => @served, "shed" => @shed,
          "logs_dropped" => @log.respond_to?(:dropped) ? @log.dropped : 0 }
      end
    end

    def start
      @socket = TCPServer.new(@host, @port)
      @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      @running = true
      trap_signals
      yield self if block_given?

      # Poll with IO.select instead of a bare blocking accept. A blocked
      # accept cannot be unwound cleanly from a signal handler, so Ctrl-C
      # either hangs or corrupts the socket. Here the trap only flips a
      # flag and the loop notices within half a second.
      while @running
        client = accept_one
        next if client.nil?

        if at_capacity?
          shed(client)
          next
        end

        spawn_worker(client)
      end
    rescue Errno::EADDRINUSE
      raise Errno::EADDRINUSE, "port #{@port} is already in use. Try: mission_control server --port #{@port + 1}"
    ensure
      close_socket
      @log.close if @log.respond_to?(:close)
    end

    def stop
      @running = false
    end

    def close_socket
      @running = false
      begin
        @socket&.close unless @socket&.closed?
      rescue StandardError
        nil
      end
    end

    def url
      shown = %w[0.0.0.0 ::].include?(@host) ? "127.0.0.1" : @host
      "http://#{shown}:#{@port}"
    end

    private

    # ---------- accept ----------

    def accept_one
      ready = IO.select([@socket], nil, nil, 0.5)
      return nil if ready.nil?

      client = @socket.accept_nonblock(exception: false)
      return nil if client == :wait_readable

      client
    rescue IOError, Errno::EBADF
      @running = false
      nil
    rescue Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR, Errno::EINVAL
      nil
    rescue Errno::EMFILE, Errno::ENFILE
      # Out of file descriptors. Backing off beats dying: the descriptors
      # held by in-flight requests will come back.
      @log << "out of file descriptors; pausing briefly"
      sleep 0.25
      nil
    rescue StandardError => e
      @log << "accept error: #{e.class}: #{e.message}"
      sleep 0.05
      nil
    end

    def at_capacity?
      @lock.synchronize { @active >= MAX_CONNECTIONS }
    end

    def shed(client)
      @lock.synchronize { @shed += 1 }
      respond(client, 503, "text/plain", "Server busy, retry shortly\n")
    ensure
      close_quietly(client)
    end

    def spawn_worker(client)
      @lock.synchronize { @active += 1 }
      Thread.new(client) do |conn|
        begin
          serve(conn)
        rescue StandardError => e
          @log << "error: #{e.class}: #{e.message}"
        ensure
          close_quietly(conn)
          @lock.synchronize { @active -= 1 }
        end
      end
    rescue ThreadError => e
      # Cannot create a thread (resource limits). Shed this one and keep
      # the listener alive rather than tearing the server down.
      @lock.synchronize { @active -= 1 }
      @log << "could not start worker: #{e.message}"
      shed(client)
    end

    # ---------- serve ----------

    def serve(conn)
      started = Time.now
      deadline = started + IDLE_TIMEOUT

      line = read_line(conn, deadline)
      return if line.nil? || line.strip.empty?

      method, target, = line.strip.split(/\s+/, 3)
      return respond(conn, 400, "text/plain", "Bad request\n") if method.nil? || target.nil?

      headers = read_headers(conn, deadline)
      return respond(conn, 408, "text/plain", "Request timed out\n") if headers.nil?

      length = headers["content-length"].to_i
      return respond(conn, 413, "text/plain", "Body too large\n") if length > MAX_BODY

      body_in = length.positive? ? read_body(conn, length, deadline) : ""
      return respond(conn, 408, "text/plain", "Request body timed out\n") if body_in.nil?

      uri = begin
        URI.parse(target)
      rescue URI::InvalidURIError
        nil
      end
      return respond(conn, 400, "text/plain", "Bad request URI\n") if uri.nil?

      params = parse_query(uri.query)
      status, type, body = @app.call(method.upcase, uri.path.to_s, params, body_in, headers)

      # Respond FIRST, log after. The previous order meant a paused console
      # could hold the response hostage; now the client always gets its
      # answer before anything touches an output stream.
      respond(conn, status, type, body, head: method.upcase == "HEAD")

      @lock.synchronize { @served += 1 }
      @log << format("%s %s -> %d (%dms)", method, target, status,
                     ((Time.now - started) * 1000).round)
    end

    # ---------- bounded reads ----------

    def readable?(conn, deadline)
      remaining = deadline - Time.now
      return false if remaining <= 0

      !IO.select([conn], nil, nil, remaining).nil?
    rescue IOError, Errno::EBADF
      false
    end

    def read_line(conn, deadline)
      return nil unless readable?(conn, deadline)

      conn.gets("\r\n", MAX_REQUEST_LINE)
    rescue StandardError
      nil
    end

    def read_headers(conn, deadline)
      headers = {}
      count = 0
      loop do
        line = read_line(conn, deadline)
        return nil if line.nil?
        return headers if line == "\r\n" || line == "\n"
        return headers if (count += 1) > MAX_HEADERS

        k, v = line.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip if k && v
      end
    end

    def read_body(conn, length, deadline)
      buffer = +""
      while buffer.bytesize < length
        return nil unless readable?(conn, deadline)

        chunk = begin
          conn.readpartial([length - buffer.bytesize, 16_384].min)
        rescue EOFError
          return buffer # client hung up early; hand over what we got
        rescue StandardError
          return nil
        end
        buffer << chunk
      end
      buffer
    end

    # ---------- respond ----------

    def parse_query(query)
      return {} if query.nil? || query.empty?

      query.split("&").each_with_object({}) do |pair, acc|
        k, v = pair.split("=", 2)
        next if k.nil? || k.empty?

        acc[URI.decode_www_form_component(k)] = URI.decode_www_form_component(v.to_s)
      rescue ArgumentError
        next
      end
    end

    def respond(conn, status, type, body, head: false)
      body = body.to_s.dup.force_encoding(Encoding::BINARY)
      headers = [
        "HTTP/1.1 #{status} #{STATUS[status] || 'OK'}",
        "Content-Type: #{type}",
        "Content-Length: #{body.bytesize}",
        "Cache-Control: no-store",
        "Connection: close",
        "", ""
      ].join("\r\n")

      write_all(conn, headers)
      write_all(conn, body) unless head || status == 204
      status
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    # A client that stops reading must not pin this thread forever either.
    def write_all(conn, data)
      deadline = Time.now + WRITE_TIMEOUT
      offset = 0
      while offset < data.bytesize
        remaining = deadline - Time.now
        break if remaining <= 0
        next unless IO.select(nil, [conn], nil, remaining)

        written = conn.write_nonblock(data.byteslice(offset, data.bytesize - offset),
                                      exception: false)
        next if written == :wait_writable

        offset += written.to_i
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    def close_quietly(conn)
      conn&.close
    rescue StandardError
      nil
    end

    # Handlers do nothing but set a flag. No IO, no locks, no allocation
    # of consequence - anything else is unsafe inside a trap context.
    def trap_signals
      %w[INT TERM].each do |sig|
        next unless Signal.list.key?(sig)

        begin
          Signal.trap(sig) { @running = false }
        rescue ArgumentError
          next # signal not supported on this platform
        end
      end
    end
  end
end
