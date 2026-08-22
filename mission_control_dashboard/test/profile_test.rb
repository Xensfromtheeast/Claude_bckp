# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "mission_control_dashboard"

class ProfileTest < Minitest::Test
  include MissionControlDashboard

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "profile.yml")
    @profile = Profile.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def snap(booked: 0.0, tasks: [])
    { "stats" => { "hours_booked" => booked }, "tasks" => tasks }
  end

  def test_absent_profile_is_inert
    refute @profile.exist?
    assert_equal false, @profile.summary["set"]
    assert_empty @profile.review(snap(booked: 200.0))
  end

  def test_seed_template_installs_but_activates_nothing
    assert @profile.install_seed
    refute @profile.install_seed, "must not overwrite without force"
    assert @profile.exist?
    # Every field ships commented out: the operator writes their own
    # profile, so a fresh template must change no behaviour at all.
    assert_equal false, @profile.summary["set"]
    assert_empty @profile.review(snap(booked: 200.0))
  end

  def test_weekly_hours_overrun_warns
    File.write(@path, "weekly_hours: 10\n")
    warnings = @profile.review(snap(booked: 12.5))
    assert_equal 1, warnings.length
    assert_match(/12\.5h/, warnings[0])
    assert_match(/10h/, warnings[0])
  end

  def test_booking_within_declared_hours_stays_quiet
    File.write(@path, "weekly_hours: 40\n")
    assert_empty @profile.review(snap(booked: 12.0))
  end

  def test_focus_tracks_flag_open_offtrack_work
    File.write(@path, "focus_tracks: [Studio]\n")
    tasks = [
      { "title" => "In focus", "track" => "Studio", "status" => "todo",
        "effort" => 8.0, "progress" => 0.0 },
      { "title" => "Off focus", "track" => "Ops", "status" => "todo",
        "effort" => 4.0, "progress" => 0.5 },
      { "title" => "Finished elsewhere", "track" => "Ops", "status" => "done",
        "effort" => 9.0, "progress" => 1.0 },
      { "title" => "Case match", "track" => "studio", "status" => "todo",
        "effort" => 3.0, "progress" => 0.0 }
    ]
    warnings = @profile.review(snap(tasks: tasks))
    assert_equal 1, warnings.length
    assert_match(/2\.0h/, warnings[0]) # 4h at 50% done
    assert_match(/Off focus/, warnings[0])
    refute_match(/Case match/, warnings[0]) # track match is case-insensitive
    refute_match(/Finished elsewhere/, warnings[0]) # done work is not drift
  end

  def test_offtrack_work_under_an_hour_is_not_nagged_about
    File.write(@path, "focus_tracks: [Studio]\n")
    tasks = [{ "title" => "Tiny errand", "track" => "Ops", "status" => "todo",
               "effort" => 0.5, "progress" => 0.0 }]
    assert_empty @profile.review(snap(tasks: tasks))
  end

  def test_broken_profile_never_takes_the_board_down
    File.write(@path, "focus_tracks: [unclosed")
    assert_equal false, @profile.summary["set"]
    assert_empty @profile.review(snap(booked: 200.0))
  end

  def test_summary_carries_the_fields_the_ui_needs
    File.write(@path, <<~YAML)
      operator: Xens
      weekly_hours: 45
      focus_tracks: [Client, Studio]
    YAML
    s = @profile.summary
    assert s["set"]
    assert_equal "Xens", s["operator"]
    assert_equal 45.0, s["weekly_hours"]
    assert_equal %w[Client Studio], s["focus_tracks"]
  end

  def test_app_merges_profile_summary_and_warnings_into_the_snapshot
    board_path = File.join(@dir, "board.yml")
    File.write(board_path, <<~YAML)
      tasks:
        - title: Big block
          track: Ops
          start: "mon 09:00"
          duration: 8
    YAML
    File.write(@path, "weekly_hours: 5\n")

    app = App.new(Board.new(board_path), profile: @profile)
    _s, _t, body = app.call("GET", "/api/board")
    doc = JSON.parse(body)

    assert doc["profile"]["set"]
    assert_equal 5.0, doc["profile"]["weekly_hours"]
    assert(doc["warnings"].any? { |w| w.include?("5h week") },
           "profile overrun must land in the board warnings: #{doc['warnings'].inspect}")
  end
end
