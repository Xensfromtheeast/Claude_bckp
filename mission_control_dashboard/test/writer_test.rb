# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "mission_control_dashboard"

class WriterTest < Minitest::Test
  include MissionControlDashboard

  ANNOTATED = <<~YAML
    # ============================================
    #  Header comment that must survive everything
    # ============================================

    meta:
      title: Mission Control   # inline comment on meta
      day_start: "07:00"

    goal:
      label: Ship it
      due: "fri 17:00"

    tasks:
      # a comment introducing the first task
      - id: alpha
        title: First task
        track: Studio
        start: "mon 09:00"
        duration: 4          # <-- ESTIMATE
        status: todo

      # a comment between tasks
      - id: beta
        title: Second task
        track: Backend
        start: "wed 10:00"
        end: "wed 14:00"
        status: blocked
        notes: Waiting on IT.

    # ============================================
    #  Trailing block that must also survive
    # ============================================
  YAML

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "board.yml")
    File.write(@path, ANNOTATED)
    @w = Writer.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def body = File.read(@path, encoding: "UTF-8")

  def tasks = YAML.safe_load(body)["tasks"]

  # The whole reason this class exists.
  def assert_comments_survive
    [
      "#  Header comment that must survive everything",
      "# a comment introducing the first task",
      "# a comment between tasks",
      "#  Trailing block that must also survive",
      "title: Mission Control   # inline comment on meta"
    ].each { |c| assert_includes body, c, "lost comment: #{c}" }
  end

  def test_update_preserves_every_other_byte
    @w.update_task("beta", { "status" => "in_progress", "notes" => "IT unblocked us." })
    assert_comments_survive
    assert_includes body, "duration: 4          # <-- ESTIMATE", "untouched task keeps its inline comment"

    beta = tasks.find { |t| t["id"] == "beta" }
    assert_equal "in_progress", beta["status"]
    assert_equal "IT unblocked us.", beta["notes"]
    assert_equal "wed 10:00", beta["start"], "untouched fields survive the rewrite"
  end

  def test_add_appends_without_disturbing_the_trailing_block
    @w.add_task({ "id" => "gamma", "title" => "Third task", "track" => "Ops",
                  "start" => "thu 09:00", "duration" => 2 })
    assert_comments_survive
    assert_equal %w[alpha beta gamma], tasks.map { |t| t["id"] }
    assert_equal "Third task", tasks.last["title"]
  end

  def test_delete_removes_only_that_task
    @w.delete_task("alpha")
    assert_comments_survive
    assert_equal %w[beta], tasks.map { |t| t["id"] }
    assert_includes body, "Waiting on IT."
  end

  def test_round_trip_is_still_a_loadable_board
    @w.add_task({ "id" => "gamma", "title" => "Third", "start" => "thu 09:00", "duration" => 2 })
    @w.update_task("alpha", { "status" => "done" })
    @w.delete_task("beta")

    snap = Board.new(@path).snapshot
    assert_empty snap["warnings"]
    assert_equal %w[alpha gamma], snap["tasks"].map { |t| t["id"] }
    assert_equal "Ship it", snap["goal"]["label"]
  end

  def test_stale_revision_is_rejected
    stale = @w.revision
    @w.update_task("alpha", { "status" => "done" }) # someone else writes first
    err = assert_raises(Writer::ConflictError) do
      @w.update_task("beta", { "status" => "done" }, rev: stale)
    end
    assert_match(/changed since this page loaded/, err.message)
    assert_equal "blocked", tasks.find { |t| t["id"] == "beta" }["status"], "the losing write must not land"
  end

  def test_matching_revision_is_accepted
    @w.update_task("alpha", { "status" => "done" }, rev: @w.revision)
    assert_equal "done", tasks.find { |t| t["id"] == "alpha" }["status"]
  end

  def test_a_backup_is_left_behind
    @w.update_task("alpha", { "status" => "done" })
    assert File.exist?("#{@path}.bak")
    assert_includes File.read("#{@path}.bak"), "status: todo", "backup holds the pre-write state"
  end

  def test_unknown_id_raises_without_touching_the_file
    before = body
    assert_raises(Writer::WriteError) { @w.update_task("nope", { "status" => "done" }) }
    assert_equal before, body
  end

  def test_values_needing_quotes_are_quoted
    @w.add_task({ "id" => "q", "title" => "Bounce: stems + VO", "start" => "thu 14:00",
                  "duration" => 2, "notes" => "10:00 sharp - #1 priority" })
    # If quoting were wrong this would raise or mangle the values.
    t = tasks.find { |x| x["id"] == "q" }
    assert_equal "Bounce: stems + VO", t["title"]
    assert_equal "10:00 sharp - #1 priority", t["notes"]
    assert_equal "thu 14:00", t["start"]
  end

  def test_times_are_always_quoted_so_yaml_does_not_sexagesimalise_them
    @w.add_task({ "id" => "t", "title" => "X", "start" => "09:00", "end" => "17:00", "duration" => 1 })
    assert_includes body, 'start: "09:00"'
    assert_equal "09:00", tasks.find { |x| x["id"] == "t" }["start"]
  end

  def test_checklist_round_trips_with_tick_state
    @w.update_task("alpha", { "checklist" => [
                      { "title" => "Draft", "done" => true },
                      { "title" => "Review", "done" => false }
                    ] })
    assert_includes body, "- x Draft"
    assert_includes body, "- Review"
    assert_in_delta 0.5, Board.new(@path).snapshot["tasks"].first["progress"], 0.001
  end

  def test_writes_into_a_board_with_no_tasks_key
    path = File.join(@dir, "empty.yml")
    File.write(path, "# just a header\nmeta:\n  title: Bare\n")
    w = Writer.new(path)
    w.add_task({ "id" => "first", "title" => "First ever", "start" => "mon 09:00", "duration" => 1 })

    assert_includes File.read(path), "# just a header"
    assert_equal ["first"], Board.new(path).snapshot["tasks"].map { |t| t["id"] }
  end

  def test_writes_into_an_inline_empty_tasks_list
    path = File.join(@dir, "inline.yml")
    File.write(path, "meta:\n  title: Bare\ntasks: []\n")
    w = Writer.new(path)
    w.add_task({ "id" => "first", "title" => "First", "start" => "mon 09:00", "duration" => 1 })
    assert_equal ["first"], Board.new(path).snapshot["tasks"].map { |t| t["id"] }
  end

  def test_tasks_without_explicit_ids_are_addressable_by_position
    path = File.join(@dir, "noid.yml")
    File.write(path, "tasks:\n  - {title: One, start: \"mon 09:00\"}\n  - {title: Two, start: \"tue 09:00\"}\n")
    w = Writer.new(path)
    w.update_task("t1", { "status" => "done" }) # Board names the 2nd row t1
    assert_equal "done", YAML.safe_load(File.read(path))["tasks"][1]["status"]
  end

  def test_utf8_survives_a_write
    @w.update_task("alpha", { "notes" => "Nairobi — 0400 recovery, café mix" })
    assert_includes body, "Nairobi — 0400 recovery, café mix"
    assert_equal "Nairobi — 0400 recovery, café mix",
                 Board.new(@path).snapshot["tasks"].first["notes"]
  end
end
