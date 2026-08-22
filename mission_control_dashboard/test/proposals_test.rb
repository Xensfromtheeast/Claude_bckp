# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "mission_control_dashboard"

class ProposalsTest < Minitest::Test
  include MissionControlDashboard

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "proposals.yml")
    @q = Proposals.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_list_and_remove
    added = @q.add([{ "title" => "Alpha", "source" => "c.md", "line" => 3 },
                    { "title" => "Beta", "source" => "c.md", "line" => 9 }])
    assert_equal 2, added.length
    assert_equal 2, @q.count
    assert(added.all? { |p| p["id"].match?(Proposals::ID_RE) })

    gone = @q.remove(added[0]["id"])
    assert_equal "Alpha", gone["title"]
    assert_equal 1, @q.count
    assert_raises(Proposals::ProposalError) { @q.remove("nope") }
  end

  def test_ignores_untitled_candidates
    assert_empty @q.add([{ "title" => "  " }, { "notes" => "no title" }, "junk"])
    assert_equal 0, @q.count
  end

  def test_deduplicates_against_what_is_already_queued
    @q.add([{ "title" => "Alpha", "source" => "c.md" }])
    assert_empty @q.add([{ "title" => "alpha", "source" => "c.md" }]),
                 "same title and source is already queued"
    assert_equal 1, @q.add([{ "title" => "Alpha", "source" => "other.md" }]).length,
                 "same title from a different chat is a real second candidate"
  end

  def test_drops_fields_that_are_not_task_fields
    p = @q.add([{ "title" => "Alpha", "evil" => "rm -rf", "id" => "attacker-chosen",
                  "track" => "Studio" }]).first
    refute p.key?("evil")
    assert_equal "Studio", p["track"]
    refute_equal "attacker-chosen", p["id"], "ids are derived here, never accepted from input"
  end

  def test_numeric_fields_are_coerced_and_junk_dropped
    p = @q.add([{ "title" => "A", "effort" => "3.5", "progress" => "nonsense" }]).first
    assert_equal 3.5, p["effort"]
    refute p.key?("progress")
  end

  def test_checklist_is_normalised
    p = @q.add([{ "title" => "A", "checklist" => ["Step one", { "title" => "Two", "done" => true }, ""] }]).first
    assert_equal [{ "title" => "Step one", "done" => false }, { "title" => "Two", "done" => true }],
                 p["checklist"]
  end

  def test_queue_is_bounded
    assert_raises(Proposals::ProposalError) do
      @q.add((1..(Proposals::MAX_OPEN + 5)).map { |i| { "title" => "T#{i}" } })
    end
  end

  def test_to_task_strips_review_metadata
    p = @q.add([{ "title" => "Alpha", "source" => "c.md", "evidence" => "said so",
                  "track" => "Studio" }]).first
    attrs = @q.to_task(p)
    assert_equal "Alpha", attrs["title"]
    assert_equal "Studio", attrs["track"]
    %w[id source line evidence origin created].each { |k| refute attrs.key?(k), "#{k} must not reach the board" }
  end

  def test_broken_queue_file_never_takes_the_dashboard_down
    File.write(@path, "proposals: [unclosed")
    assert_equal 0, @q.count
    assert_empty @q.list
  end

  def test_clear_empties_the_queue
    @q.add([{ "title" => "A" }, { "title" => "B" }])
    assert_equal 2, @q.clear
    assert_equal 0, @q.count
  end
end

# The import -> review -> accept path through App, which is the only route
# from a chat log to board.yml.
class ImportAppTest < Minitest::Test
  include MissionControlDashboard

  H = { "host" => "127.0.0.1:4567", "x-mission-control" => "1" }.freeze

  CHAT = <<~MD
    ## Next steps
    - Cut 3 brand stingers (5h) Wednesday 10am
    - Master bus pass Thursday
  MD

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "board.yml")
    File.write(@path, <<~YAML)
      meta:
        title: Test
      tasks:
        - id: existing
          title: Existing task
          track: Studio
          start: "mon 09:00"
          duration: 2
    YAML
    @board = Board.new(@path)
    @queue = Proposals.new(Proposals.default_path(@path))
    @app = App.new(@board, proposals: @queue)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def post(path, payload, headers = H)
    @app.call("POST", path, {}, JSON.generate(payload), headers)
  end

  def test_import_queues_without_touching_the_board
    before = File.read(@path)

    status, _t, body = post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    assert_equal 201, status
    doc = JSON.parse(body)
    assert_equal 2, doc["found"]
    assert_equal 2, doc["added"]
    assert_equal 2, doc["open"]

    assert_equal before, File.read(@path), "importing must never write to the board"
  end

  def test_import_requires_the_anti_csrf_header
    status, = post("/api/import", { "text" => CHAT }, { "host" => "127.0.0.1" })
    assert_equal 403, status
  end

  def test_import_rejects_empty_text
    status, = post("/api/import", { "text" => "   " })
    assert_equal 422, status
  end

  def test_read_only_server_refuses_import_and_accept
    ro = App.new(@board, read_only: true, proposals: @queue)
    status, = ro.call("POST", "/api/import", {}, JSON.generate("text" => CHAT), H)
    assert_equal 403, status
  end

  def test_proposals_index_lists_the_queue
    post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    status, _t, body = @app.call("GET", "/api/proposals")
    assert_equal 200, status
    rows = JSON.parse(body)["proposals"]
    assert_equal 2, rows.length
    assert_includes rows.map { |r| r["title"] }, "Cut 3 brand stingers"
  end

  def test_proposals_are_flagged_when_the_board_already_has_that_task
    post("/api/import", { "text" => "- [ ] Existing task\n- [ ] Brand new thing",
                          "source" => "c.md" })
    _s, _t, body = @app.call("GET", "/api/proposals")
    rows = JSON.parse(body)["proposals"].each_with_object({}) { |r, h| h[r["title"]] = r }

    assert rows["Existing task"]["duplicate"], "a title already on the board must be flagged"
    refute rows["Brand new thing"]["duplicate"]
  end

  def test_accept_writes_through_the_normal_task_path_and_dequeues
    post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    id = @queue.list.find { |p| p["title"] == "Cut 3 brand stingers" }["id"]

    status, _t, body = post("/api/proposals/#{id}/accept", {})
    assert_equal 201, status
    assert_equal 1, JSON.parse(body)["open"], "an accepted proposal leaves the queue"

    task = @board.snapshot["tasks"].find { |t| t["title"] == "Cut 3 brand stingers" }
    refute_nil task, "accepting must put it on the board"
    assert_equal 5.0, task["effort"]
    assert_equal 3, Time.parse(task["start"]).wday, "Wednesday, as the chat said"

    # Review metadata must not leak into the YAML.
    raw = File.read(@path)
    refute_includes raw, "evidence"
    refute_includes raw, "chat.md"
  end

  def test_accepting_twice_is_a_404_not_a_duplicate
    post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    id = @queue.list.first["id"]
    assert_equal 201, post("/api/proposals/#{id}/accept", {}).first
    assert_equal 404, post("/api/proposals/#{id}/accept", {}).first
  end

  def test_a_proposal_with_no_time_still_lands_somewhere_real
    post("/api/import", { "text" => "- [ ] Rework the low end", "source" => "c.md" })
    id = @queue.list.first["id"]
    assert_equal 201, post("/api/proposals/#{id}/accept", {}).first

    task = @board.snapshot["tasks"].find { |t| t["title"] == "Rework the low end" }
    refute_nil task
    assert_operator task["hours"], :>, 0
  end

  def test_discard_removes_without_touching_the_board
    post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    id = @queue.list.first["id"]
    before = File.read(@path)

    status, _t, body = @app.call("DELETE", "/api/proposals/#{id}", {}, "", H)
    assert_equal 200, status
    assert_equal 1, JSON.parse(body)["open"]
    assert_equal before, File.read(@path)

    assert_equal 404, @app.call("DELETE", "/api/proposals/#{id}", {}, "", H).first
  end

  def test_board_reports_the_open_count
    _s, _t, body = @app.call("GET", "/api/board")
    assert_equal 0, JSON.parse(body)["proposals_open"]

    post("/api/import", { "text" => CHAT, "source" => "chat.md" })
    _s, _t, body = @app.call("GET", "/api/board")
    assert_equal 2, JSON.parse(body)["proposals_open"]
  end
end
