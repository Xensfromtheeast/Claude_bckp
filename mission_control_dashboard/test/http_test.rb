# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "net/http"
require "mission_control_dashboard"

# Exercises the hand-rolled socket server end to end: real client, real
# request parsing, real shutdown. The custom server is the riskiest part
# of the gem, so it does not get to be untested.
class HTTPTest < Minitest::Test
  include MissionControlDashboard

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "board.yml")
    Board.install_seed(@path)
    @port = 40_000 + rand(20_000)
    board = Board.new(@path)
    @server = HTTPServer.new(App.new(board, writer: Writer.new(@path)),
                             host: "127.0.0.1", port: @port, quiet: true)
    @thread = Thread.new { @server.start }
    wait_for_boot
  end

  def teardown
    @server.stop
    @thread&.join(3)
    FileUtils.remove_entry(@dir)
  end

  def wait_for_boot
    30.times do
      TCPSocket.new("127.0.0.1", @port).close
      return true
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end
    flunk "server never came up on port #{@port}"
  end

  def get(path)
    Net::HTTP.start("127.0.0.1", @port) { |h| h.request(Net::HTTP::Get.new(path)) }
  end

  def test_serves_structured_pickers_and_history_route
    res = get("/")
    assert_includes res.body, 'id="f-start-day"'
    assert_includes res.body, 'id="f-end-day"'
    assert_includes res.body, 'id="arch"'

    res = get("/api/history")
    assert_equal "200", res.code
    assert_equal [], JSON.parse(res.body)["weeks"]
  end

  def test_serves_the_dashboard
    res = get("/")
    assert_equal "200", res.code
    assert_match %r{text/html}, res["content-type"]
    assert_includes res.body, "Week Timeline"
    assert_includes res.body, "board-data"
    assert_equal res.body.bytesize.to_s, res["content-length"]
  end

  def test_serves_json_and_honours_query_params
    res = get("/api/board?week=2")
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal 2, body["meta"]["week_offset"]
    assert_operator body["tasks"].length, :>, 0
  end

  def test_unknown_path_is_404_not_a_crash
    assert_equal "404", get("/definitely/not/here").code
  end

  def test_write_methods_are_guarded_before_they_are_routed
    # No CSRF header: refused without revealing whether the route exists.
    res = Net::HTTP.start("127.0.0.1", @port) { |h| h.request(Net::HTTP::Post.new("/")) }
    assert_equal "403", res.code

    # With the header it is simply not a write route.
    assert_equal "404", post("/", {}).code
  end

  def test_genuinely_unsupported_methods_are_405
    req = Net::HTTP::Options.new("/")
    res = Net::HTTP.start("127.0.0.1", @port) { |h| h.request(req) }
    assert_equal "405", res.code
  end

  def test_head_returns_headers_without_a_body
    res = Net::HTTP.start("127.0.0.1", @port) { |h| h.request(Net::HTTP::Head.new("/")) }
    assert_equal "200", res.code
    assert_nil res.body
  end

  def test_handles_concurrent_requests
    codes = 8.times.map { Thread.new { get("/api/board").code } }.map(&:value)
    assert_equal ["200"] * 8, codes
  end

  # ---------- writes ----------

  def post(path, payload, headers = { "X-Mission-Control" => "1" })
    req = Net::HTTP::Post.new(path, headers.merge("Content-Type" => "application/json"))
    req.body = JSON.generate(payload)
    Net::HTTP.start("127.0.0.1", @port) { |h| h.request(req) }
  end

  def patch(path, payload, headers = { "X-Mission-Control" => "1" })
    req = Net::HTTP::Patch.new(path, headers.merge("Content-Type" => "application/json"))
    req.body = JSON.generate(payload)
    Net::HTTP.start("127.0.0.1", @port) { |h| h.request(req) }
  end

  def rev
    JSON.parse(get("/api/board").body)["rev"]
  end

  def test_creates_a_task_and_it_appears_in_the_board
    res = post("/api/tasks", { rev: rev, task: { title: "Bounce stems", track: "Studio",
                                                 start: "thu 14:00", duration: 2 } })
    assert_equal "201", res.code
    id = JSON.parse(res.body)["id"]
    assert_equal "bounce-stems", id

    titles = JSON.parse(get("/api/board").body)["tasks"].map { |t| t["title"] }
    assert_includes titles, "Bounce stems"
  end

  def test_updates_and_deletes_round_trip
    post("/api/tasks", { rev: rev, task: { title: "Temp", start: "thu 14:00", duration: 1 } })
    assert_equal "200", patch("/api/tasks/temp", { rev: rev, task: { status: "blocked" } }).code

    task = JSON.parse(get("/api/board").body)["tasks"].find { |t| t["id"] == "temp" }
    assert_equal "blocked", task["status"]

    req = Net::HTTP::Delete.new("/api/tasks/temp", "X-Mission-Control" => "1")
    res = Net::HTTP.start("127.0.0.1", @port) { |h| h.request(req) }
    assert_equal "200", res.code
    refute_includes JSON.parse(get("/api/board").body)["tasks"].map { |t| t["id"] }, "temp"
  end

  def test_write_without_the_csrf_header_is_refused
    res = post("/api/tasks", { task: { title: "Evil", start: "mon 09:00" } }, {})
    assert_equal "403", res.code
    refute_includes JSON.parse(get("/api/board").body)["tasks"].map { |t| t["title"] }, "Evil"
  end

  def test_write_to_a_non_loopback_host_header_is_refused
    res = post("/api/tasks", { task: { title: "Rebind", start: "mon 09:00", duration: 1 } },
               { "X-Mission-Control" => "1", "Host" => "attacker.example.com" })
    assert_equal "403", res.code
  end

  def test_stale_revision_gets_a_409
    stale = rev
    post("/api/tasks", { rev: stale, task: { title: "First in", start: "thu 09:00", duration: 1 } })
    res = post("/api/tasks", { rev: stale, task: { title: "Second in", start: "thu 09:00", duration: 1 } })
    assert_equal "409", res.code
    refute_includes JSON.parse(get("/api/board").body)["tasks"].map { |t| t["title"] }, "Second in"
  end

  def test_invalid_payloads_are_rejected_with_reasons
    assert_equal "422", post("/api/tasks", { task: { start: "mon 09:00" } }).code
    assert_equal "422", post("/api/tasks", { task: { title: "x", start: "gibberish", duration: 1 } }).code
    assert_equal "422", post("/api/tasks", { task: { title: "x", start: "mon 09:00", status: "banana" } }).code
    assert_equal "422", post("/api/tasks", { task: { title: "x", start: "mon 09:00", effort: -3 } }).code

    body = JSON.parse(post("/api/tasks", { task: { title: "x", start: "gibberish", duration: 1 } }).body)
    assert_match(/Could not read start/, body["error"])
  end

  def test_unknown_keys_are_not_smuggled_into_the_file
    post("/api/tasks", { rev: rev, task: { title: "Clean", start: "thu 14:00", duration: 1,
                                           evil: "rm -rf", "meta" => { "title" => "pwned" } } })
    raw = File.read(@path, encoding: "UTF-8")
    refute_includes raw, "evil"
    refute_includes raw, "pwned"
  end

  def test_read_only_mode_refuses_writes
    ro_port = 40_000 + rand(20_000)
    board = Board.new(@path)
    app = App.new(board, writer: Writer.new(@path), read_only: true)
    server = HTTPServer.new(app, host: "127.0.0.1", port: ro_port, quiet: true)
    thread = Thread.new { server.start }
    30.times do
      TCPSocket.new("127.0.0.1", ro_port).close
      break
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end

    req = Net::HTTP::Post.new("/api/tasks", "Content-Type" => "application/json",
                                            "X-Mission-Control" => "1")
    req.body = JSON.generate(task: { title: "Nope", start: "mon 09:00", duration: 1 })
    res = Net::HTTP.start("127.0.0.1", ro_port) { |h| h.request(req) }
    assert_equal "403", res.code
    assert_match(/read-only/, JSON.parse(res.body)["error"])

    body = Net::HTTP.start("127.0.0.1", ro_port) { |h| h.request(Net::HTTP::Get.new("/api/board")) }
    assert JSON.parse(body.body)["read_only"], "the UI needs to know to hide its edit controls"
  ensure
    server&.stop
    thread&.join(3)
  end

  def test_garbage_request_does_not_kill_the_server
    sock = TCPSocket.new("127.0.0.1", @port)
    sock.write("not a real http request\r\n\r\n")
    sock.read
    sock.close
    assert_equal "200", get("/healthz").code, "server must survive malformed input"
  end
end
