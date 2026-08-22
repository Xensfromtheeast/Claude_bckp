# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "mission_control_dashboard"

class BoardTest < Minitest::Test
  include MissionControlDashboard

  def with_board(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "board.yml")
      File.write(path, yaml)
      yield Board.new(path)
    end
  end

  # Tuesday 12:00, so "mon"/"wed" land either side of now.
  def now
    @now ||= Time.new(2026, 8, 11, 12, 0, 0)
  end

  def test_seed_board_is_valid_and_parses
    Dir.mktmpdir do |dir|
      path = File.join(dir, "board.yml")
      assert Board.install_seed(path)
      refute Board.install_seed(path), "should not overwrite without force"
      assert Board.install_seed(path, force: true)

      snap = Board.new(path).snapshot(now: now)
      assert_empty snap["warnings"]
      assert_equal 11, snap["tasks"].length
      assert snap["goal"]["set"]
    end
  end

  def test_weekday_relative_times_resolve_into_the_viewed_week
    with_board(<<~Y) do |b|
      tasks:
        - title: A
          start: "mon 09:00"
          duration: 2
    Y
      t = b.snapshot(now: now)["tasks"].first
      start = Time.parse(t["start"])
      assert_equal 1, start.wday, "should land on Monday"
      assert_equal [9, 0], [start.hour, start.min]
      assert_equal 2.0, t["hours"]
    end
  end

  def test_week_offset_shifts_relative_tasks
    with_board(<<~Y) do |b|
      tasks:
        - title: A
          start: "mon 09:00"
    Y
      this_week = Time.parse(b.snapshot(now: now)["tasks"].first["start"])
      next_week = Time.parse(b.snapshot(now: now, week_offset: 1)["tasks"].first["start"])
      assert_equal 7 * 86_400, (next_week - this_week).to_i
    end
  end

  def test_absolute_timestamps_pin_to_real_dates
    with_board(<<~Y) do |b|
      tasks:
        - title: A
          start: "2026-08-14 17:00"
          end: "2026-08-14 18:30"
    Y
      t = b.snapshot(now: now)["tasks"].first
      assert_equal "2026-08-14", Time.parse(t["start"]).strftime("%Y-%m-%d")
      assert_equal 1.5, t["hours"]
    end
  end

  def test_states_are_derived_from_the_clock
    with_board(<<~Y) do |b|
      tasks:
        - {title: past,    start: "mon 09:00", duration: 1}
        - {title: shipped, start: "mon 09:00", duration: 1, status: done}
        - {title: running, start: "tue 11:00", duration: 2}
        - {title: later,   start: "wed 09:00", duration: 1}
        - {title: stuck,   start: "wed 09:00", duration: 1, status: blocked}
    Y
      by = b.snapshot(now: now)["tasks"].to_h { |t| [t["title"], t["state"]] }
      assert_equal "overdue",  by["past"]
      assert_equal "done",     by["shipped"]
      assert_equal "live",     by["running"]
      assert_equal "upcoming", by["later"]
      assert_equal "blocked",  by["stuck"]
    end
  end

  def test_explicit_in_progress_beats_the_calendar
    with_board(<<~Y) do |b|
      tasks:
        - {title: early, start: "fri 09:00", duration: 2, status: in_progress, progress: 0.3}
    Y
      t = b.snapshot(now: now)["tasks"].first
      assert_equal "live", t["state"], "marked in_progress should read as live even before its window"
      assert_in_delta 0.3, t["progress"]
    end
  end

  def test_capacity_compares_open_work_against_working_hours
    with_board(<<~Y) do |b|
      meta:
        day_start: "09:00"
        day_end: "17:00"
      goal:
        label: Ship it
        due: "wed 17:00"
      tasks:
        - {title: done_work, start: "mon 09:00", duration: 4, status: done}
        - {title: half,      start: "tue 13:00", duration: 4, progress: 0.5}
        - {title: whole,     start: "wed 09:00", duration: 6}
    Y
      g = b.snapshot(now: now)["goal"]
      # 4h * 0.5 remaining + 6h remaining = 8h of open work.
      assert_in_delta 8.0, g["work_left"], 0.01
      # Tue 12:00 -> Tue 17:00 = 5h, plus Wed 09:00 -> 17:00 = 8h.
      assert_in_delta 13.0, g["capacity"], 0.01
      assert_in_delta 5.0, g["slack"], 0.01
      refute g["at_risk"]
      assert_equal 1, g["tasks_done"]
    end
  end

  def test_at_risk_when_work_exceeds_remaining_working_hours
    with_board(<<~Y) do |b|
      meta: {day_start: "09:00", day_end: "17:00"}
      goal: {label: Crunch, due: "tue 17:00"}
      tasks:
        - {title: big, start: "tue 13:00", duration: 20}
    Y
      g = b.snapshot(now: now)["goal"]
      assert g["at_risk"]
      assert_operator g["slack"], :<, 0
    end
  end

  def test_percent_progress_is_tolerated
    with_board("tasks:\n  - {title: A, start: \"tue 09:00\", progress: 60}\n") do |b|
      assert_in_delta 0.6, b.snapshot(now: now)["tasks"].first["progress"]
    end
  end

  def test_status_synonyms_normalize
    with_board(<<~Y) do |b|
      tasks:
        - {title: a, start: "tue 09:00", status: WIP}
        - {title: b, start: "tue 09:00", status: Completed}
        - {title: c, start: "tue 09:00", status: waiting}
    Y
      states = b.snapshot(now: now)["tasks"].map { |t| t["status"] }
      assert_equal %w[in_progress done blocked], states
    end
  end

  def test_bad_rows_warn_instead_of_crashing
    with_board(<<~Y) do |b|
      tasks:
        - {title: fine, start: "tue 09:00"}
        - {title: no_start}
        - {start: "tue 09:00"}
        - "just a string"
        - {title: backwards, start: "tue 11:00", end: "tue 09:00"}
        - {title: weird_status, start: "tue 09:00", status: banana}
    Y
      snap = b.snapshot(now: now)
      titles = snap["tasks"].map { |t| t["title"] }
      assert_includes titles, "fine"
      refute_includes titles, "no_start"
      assert_includes titles, "backwards"
      assert_operator snap["warnings"].length, :>=, 4
      assert_equal "todo", snap["tasks"].find { |t| t["title"] == "weird_status" }["status"]
    end
  end

  def test_empty_board_is_survivable
    with_board("meta:\n  title: Nothing\n") do |b|
      snap = b.snapshot(now: now)
      assert_equal [], snap["tasks"]
      refute snap["goal"]["set"]
      assert_equal 0, snap["stats"]["total"]
    end
  end

  def test_malformed_yaml_raises_a_readable_error
    with_board("tasks:\n  - {title: unclosed\n") do |b|
      err = assert_raises(Board::BoardError) { b.snapshot(now: now) }
      assert_match(/not valid YAML/, err.message)
    end
  end

  def test_inverted_working_window_falls_back_and_warns
    with_board("meta: {day_start: \"22:00\", day_end: \"07:00\"}\n") do |b|
      snap = b.snapshot(now: now)
      assert_equal 420, snap["meta"]["day_start"]
      assert_equal 1320, snap["meta"]["day_end"]
      assert_match(/day_end/, snap["warnings"].first)
    end
  end

  def test_tasks_outside_the_working_window_are_flagged
    with_board(<<~Y) do |b|
      meta: {day_start: "09:00", day_end: "18:00"}
      tasks:
        - {title: daytime,   start: "tue 10:00", duration: 2}
        - {title: overnight, start: "tue 19:00", duration: 9}
    Y
      snap = b.snapshot(now: now)
      by = snap["tasks"].to_h { |t| [t["title"], t["clipped"]] }
      refute by["daytime"]
      assert by["overnight"]
      assert_match(/overnight/, snap["warnings"].join)
      assert_match(/09:00-18:00/, snap["warnings"].join)
    end
  end

  def test_effort_separates_hours_of_work_from_the_window_they_live_in
    with_board(<<~Y) do |b|
      meta: {day_start: "09:00", day_end: "18:00"}
      goal: {label: Ship, due: "fri 18:00"}
      tasks:
        - {title: open_all_week, start: "mon 09:00", end: "fri 18:00", effort: 8}
    Y
      snap = b.snapshot(now: now)
      t = snap["tasks"].first
      assert_in_delta 105.0, t["hours"], 0.01, "the window is still 105 hours wide"
      assert_in_delta 8.0, t["effort"], 0.01
      assert t["spanning"], "should be drawn as a window, not a solid block"
      # Capacity must count the 8h of work, not the 105h span.
      assert_in_delta 8.0, snap["goal"]["work_left"], 0.01
      assert_in_delta 8.0, snap["stats"]["hours_booked"], 0.01
    end
  end

  def test_effort_defaults_to_the_span_when_omitted
    with_board("tasks:\n  - {title: solid, start: \"tue 09:00\", duration: 3}\n") do |b|
      t = b.snapshot(now: now)["tasks"].first
      assert_in_delta 3.0, t["effort"], 0.01
      refute t["spanning"]
    end
  end

  def test_multiday_spans_are_not_flagged_as_outside_working_hours
    with_board(<<~Y) do |b|
      meta: {day_start: "09:00", day_end: "18:00"}
      tasks:
        - {title: spans_nights, start: "mon 09:00", end: "fri 18:00", effort: 8}
        - {title: genuinely_late, start: "tue 19:00", duration: 2}
        - {title: overnight, start: "tue 20:00", end: "wed 02:00"}
    Y
      snap = b.snapshot(now: now)
      by = snap["tasks"].to_h { |t| [t["title"], t["clipped"]] }
      refute by["spans_nights"], "a Mon-Fri window is not an out-of-hours booking"
      assert by["genuinely_late"]
      assert by["overnight"]
    end
  end

  def test_checklist_derives_measured_progress
    with_board(<<~Y) do |b|
      tasks:
        - title: contract
          start: "tue 09:00"
          checklist:
            - "x Finalize Contract"
            - Lock in Deliverables
            - {title: Finalize Media Plan, done: true}
            - Internal Reviews
    Y
      t = b.snapshot(now: now)["tasks"].first
      assert_equal 4, t["checklist"].length
      assert_equal 2, t["checklist"].count { |c| c["done"] }
      assert_equal "Finalize Contract", t["checklist"].first["title"]
      assert_in_delta 0.5, t["progress"], 0.001, "2 of 4 ticked = 50%"
    end
  end

  def test_explicit_progress_overrides_the_checklist
    with_board(<<~Y) do |b|
      tasks:
        - {title: a, start: "tue 09:00", progress: 0.9, checklist: [one, two, three, four]}
    Y
      assert_in_delta 0.9, b.snapshot(now: now)["tasks"].first["progress"], 0.001
    end
  end

  def test_bad_checklist_warns_and_is_ignored
    with_board("tasks:\n  - {title: a, start: \"tue 09:00\", checklist: \"not a list\"}\n") do |b|
      snap = b.snapshot(now: now)
      assert_equal [], snap["tasks"].first["checklist"]
      assert_match(/checklist must be a list/, snap["warnings"].join)
    end
  end

  def test_view_renders_and_escapes_script_tags
    with_board(<<~Y) do |b|
      tasks:
        - {title: "</script><img src=x onerror=alert(1)>", start: "tue 09:00"}
    Y
      html = MissionControlDashboard::View.render(b.snapshot(now: now))
      assert_includes html, "<!doctype html>"
      refute_includes html, "</script><img", "raw script terminator must not survive into the page"
      assert_includes html, "\\u003c/script"
    end
  end

  def test_app_routes
    with_board("tasks: []\n") do |b|
      app = MissionControlDashboard::App.new(b)
      assert_equal 200, app.call("GET", "/", {})[0]
      assert_equal 200, app.call("GET", "/api/board", { "week" => "2" })[0]
      assert_equal 200, app.call("GET", "/healthz", {})[0]
      assert_equal 404, app.call("GET", "/nope", {})[0]
      assert_equal 403, app.call("POST", "/", {})[0], "writes are guarded before routing"
      assert_equal 405, app.call("OPTIONS", "/", {})[0]

      body = JSON.parse(app.call("GET", "/api/board", { "week" => "1" })[2])
      assert_equal 1, body["meta"]["week_offset"]
      # Nonsense week values must not blow up the date math.
      assert_equal 0, JSON.parse(app.call("GET", "/api/board", { "week" => "99999" })[2])["meta"]["week_offset"]
      assert_equal 0, JSON.parse(app.call("GET", "/api/board", { "week" => "abc" })[2])["meta"]["week_offset"]
    end
  end
end
