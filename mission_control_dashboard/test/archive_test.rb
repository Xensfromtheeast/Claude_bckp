# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "mission_control_dashboard"

class ArchiveTest < Minitest::Test
  include MissionControlDashboard

  BOARD = <<~YAML
    meta:
      title: Test Board
      operator: T
      day_start: "07:00"
      day_end: "22:00"
    goal:
      label: Ship it
      due: "fri 17:00"
    tasks:
      - id: a
        title: Alpha
        track: Studio
        start: "mon 09:00"
        duration: 4
        status: done
      - id: b
        title: Beta
        track: Client
        start: "wed 10:00"
        end: "wed 14:00"
        status: todo
  YAML

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "board.yml")
    File.write(@path, BOARD)
    @board = Board.new(@path)
    @archive = Archive.new(@board)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # Tuesday, so the board's Mon/Wed tasks sit either side of now.
  def now
    Time.new(2026, 8, 11, 12, 0, 0)
  end

  def test_write_snapshots_the_week_with_absolute_dates
    saved = @archive.write(now: now)
    assert_match(/\A\d{4}-W\d{2}\z/, saved["week"])
    assert File.exist?(saved["path"])

    doc = YAML.safe_load(File.read(saved["path"]), permitted_classes: [Date, Time, DateTime])
    assert_equal saved["week"], doc["week"]
    assert_equal 2, doc["tasks"].length
    starts = doc["tasks"].map { |t| t["start"] }
    assert(starts.all? { |s| s.start_with?("2026-08-1") },
           "archived starts must be absolute dates, got #{starts.inspect}")
    assert doc["goal"]["set"]
    refute doc["meta"].key?("week_offset"), "viewer state must not be archived"
  end

  def test_week_id_is_the_iso_week_of_the_snapshot_monday
    saved = @archive.write(now: now)
    monday = Date.new(2026, 8, 10)
    assert_equal format("%04d-W%02d", monday.cwyear, monday.cweek), saved["week"]
  end

  def test_refuses_double_write_without_force
    @archive.write(now: now)
    assert_raises(Archive::ExistsError) { @archive.write(now: now) }
    @archive.write(now: now, force: true)
  end

  def test_refuses_future_weeks
    assert_raises(Archive::ArchiveError) { @archive.write(now: now, week_offset: 1) }
  end

  def test_list_is_newest_first_and_read_round_trips
    @archive.write(now: now)
    @archive.write(now: now, week_offset: -1)

    list = @archive.list
    assert_equal 2, list.length
    assert_operator list[0]["week"], :>, list[1]["week"]
    assert_equal 2, list[0]["tasks"]
    assert_equal 1, list[0]["done"]
    assert_equal "Ship it", list[0]["goal"]

    doc = @archive.read(list[1]["week"])
    assert_equal list[1]["week"], doc["week"]
  end

  def test_read_rejects_anything_that_is_not_a_week_id
    @archive.write(now: now)
    assert_nil @archive.read("../../etc/passwd")
    assert_nil @archive.read("2026-W99;rm")
    assert_nil @archive.read(nil)
    assert_nil @archive.read("1999-W01") # valid shape, no file
  end
end

# The /api/history and /api/archive routes, exercised straight through
# App#call — no sockets needed to prove routing and guards.
class HistoryAppTest < Minitest::Test
  include MissionControlDashboard

  H = { "host" => "127.0.0.1:4567", "x-mission-control" => "1" }.freeze

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "board.yml")
    File.write(@path, ArchiveTest::BOARD)
    @board = Board.new(@path)
    @app = App.new(@board)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post_archive(app, payload, headers = H)
    app.call("POST", "/api/archive", {}, JSON.generate(payload), headers)
  end

  def test_archive_post_requires_the_anti_csrf_header
    status, = post_archive(@app, { "week" => 0 }, { "host" => "127.0.0.1" })
    assert_equal 403, status
  end

  def test_archive_write_conflict_force_and_future_guard
    status, _t, body = post_archive(@app, { "week" => 0 })
    assert_equal 201, status
    week = JSON.parse(body)["week"]
    assert_match(/\A\d{4}-W\d{2}\z/, week)

    status, = post_archive(@app, { "week" => 0 })
    assert_equal 409, status

    status, = post_archive(@app, { "week" => 0, "force" => true })
    assert_equal 201, status

    status, = post_archive(@app, { "week" => 2 })
    assert_equal 422, status
  end

  def test_history_index_and_show
    _s, _t, body = post_archive(@app, { "week" => 0 })
    week = JSON.parse(body)["week"]

    status, _t, body = @app.call("GET", "/api/history")
    assert_equal 200, status
    weeks = JSON.parse(body)["weeks"]
    assert_equal [week], weeks.map { |w| w["week"] }

    status, _t, body = @app.call("GET", "/api/history/#{week}")
    assert_equal 200, status
    doc = JSON.parse(body)
    assert doc["archived"]
    assert doc["read_only"], "history must be served read-only"
    assert_equal 2, doc["tasks"].length

    status, = @app.call("GET", "/api/history/1999-W01")
    assert_equal 404, status
  end

  def test_board_flags_past_weeks_that_have_an_archive
    post_archive(@app, { "week" => -1 })

    _s, _t, body = @app.call("GET", "/api/board", { "week" => "-1" })
    assert JSON.parse(body)["archive_available"],
           "a past week with an archive on disk must say so"

    _s, _t, body = @app.call("GET", "/api/board")
    refute JSON.parse(body).key?("archive_available"),
           "the current week is live, never an archive"
  end

  def test_read_only_server_refuses_archiving
    ro = App.new(@board, read_only: true)
    status, = post_archive(ro, { "week" => 0 })
    assert_equal 403, status
  end
end
