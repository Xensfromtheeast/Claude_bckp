# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "net/http"
require "timeout"
require "mission_control_dashboard"

# Regression tests for a real hang: the dashboard stayed alive and kept
# accepting connections while answering none of them, because every request
# wrote a log line *before* the response and the console had stopped draining.
#
# On Windows that happens when you click inside the console window — Quick Edit
# selection suspends console writes until you press Esc. Here we reproduce the
# identical mechanism with a pipe nobody reads: once its buffer fills, write
# blocks forever.
class LoggerTest < Minitest::Test
  include MissionControlDashboard

  def setup
    @read, @write = IO.pipe
  end

  def teardown
    @read.close unless @read.closed?
    @write.close unless @write.closed?
  end

  # Fill the pipe so any further write to it blocks.
  def block_the_pipe!
    @write.write_nonblock("x" * 65_536)
  rescue IO::WaitWritable, Errno::EAGAIN
    nil
  end

  def test_logging_never_blocks_the_caller_even_when_output_is_stuck
    block_the_pipe!
    log = SafeLogger.new(@write, enabled: true)

    # If this blocks, the bug is back.
    Timeout.timeout(5) do
      2_000.times { |i| log.write("request #{i}") }
    end

    assert_operator log.dropped, :>, 0, "should shed messages rather than block"
  end

  def test_messages_flow_normally_when_output_drains
    log = SafeLogger.new(@write, enabled: true)
    log.write("hello world")
    line = Timeout.timeout(5) { @read.gets }
    assert_match(/hello world/, line)
    assert_equal 0, log.dropped
  end

  def test_disabled_logger_is_inert
    log = SafeLogger.new(@write, enabled: false)
    log.write("nothing should happen")
    assert_equal 0, log.dropped
  end

  def test_a_broken_pipe_does_not_kill_the_writer
    log = SafeLogger.new(@write, enabled: true)
    @read.close
    log.write("into the void")
    sleep 0.2
    log.write("still alive")   # must not raise
    pass
  end

  # The end-to-end version: a server whose log output is wedged must still
  # serve HTTP.
  def test_server_keeps_serving_while_its_console_is_frozen
    dir = Dir.mktmpdir
    path = File.join(dir, "board.yml")
    Board.install_seed(path)

    block_the_pipe!
    logger = SafeLogger.new(@write, enabled: true)
    port = 40_000 + rand(20_000)
    board = Board.new(path)
    app = App.new(board, writer: Writer.new(path))
    server = HTTPServer.new(app, host: "127.0.0.1", port: port, logger: logger)
    app.server = server
    thread = Thread.new { server.start }

    40.times do
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end

    # Every one of these logs a line into an output stream that cannot accept
    # it. All of them must still get answered.
    Timeout.timeout(20) do
      30.times do
        res = Net::HTTP.start("127.0.0.1", port, read_timeout: 3) do |h|
          h.request(Net::HTTP::Get.new("/healthz"))
        end
        assert_equal "200", res.code
      end
    end

    health = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/healthz")))
    assert health["ok"]
    assert_operator health["served"], :>, 0, "health should report real traffic"
  ensure
    server&.stop
    thread&.join(3)
    FileUtils.remove_entry(dir) if dir
  end

  def test_a_client_that_says_nothing_cannot_pin_a_thread_forever
    dir = Dir.mktmpdir
    path = File.join(dir, "board.yml")
    Board.install_seed(path)
    port = 40_000 + rand(20_000)
    board = Board.new(path)
    app = App.new(board, writer: Writer.new(path))
    server = HTTPServer.new(app, host: "127.0.0.1", port: port, quiet: true)
    app.server = server
    thread = Thread.new { server.start }
    40.times do
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end

    silent = 10.times.map { TCPSocket.new("127.0.0.1", port) }
    sleep 0.3
    before = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/healthz")))
    assert_operator before["active"], :>=, 1, "the silent sockets are being held"

    # Real traffic is unaffected while they hang around.
    Timeout.timeout(10) do
      5.times { assert_equal "200", Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/healthz")).code }
    end
    silent.each { |s| s.close rescue nil }
  ensure
    server&.stop
    thread&.join(3)
    FileUtils.remove_entry(dir) if dir
  end
end
