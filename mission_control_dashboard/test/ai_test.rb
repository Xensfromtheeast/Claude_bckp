# frozen_string_literal: true

require "minitest/autorun"
require "mission_control_dashboard"

# The AI path is optional and off by default. These tests cover everything
# that must hold WITHOUT the optional gem, without a key, and without a
# network — which is the state most installs are in, and the state in which
# the rest of the dashboard still has to work perfectly.
class AITest < Minitest::Test
  include MissionControlDashboard

  def without_key
    saved = ENV.to_h.slice("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
    ENV.delete("ANTHROPIC_API_KEY")
    ENV.delete("ANTHROPIC_AUTH_TOKEN")
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def with_key
    saved = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "sk-test-not-a-real-key"
    yield
  ensure
    ENV["ANTHROPIC_API_KEY"] = saved
  end

  def test_it_says_why_it_cannot_run_instead_of_failing_obscurely
    without_key do
      reason = AI.unavailable_reason
      refute_nil reason, "with no key configured there must be a stated reason"
      assert_match(/anthropic|API key/, reason)
      assert_match(/offline parser/, reason, "must point at the path that does work")
    end
  end

  def test_propose_refuses_up_front_rather_than_calling_out
    without_key do
      err = assert_raises(AI::AIError) { AI.propose("- [ ] anything", source: "c.md") }
      assert_match(/anthropic|API key/, err.message)
    end
  end

  def test_key_detection_reads_both_supported_variables
    without_key { refute AI.key? }
    with_key { assert AI.key? }
  end

  def test_it_targets_the_current_opus_model
    assert_equal "claude-opus-5", AI::MODEL
  end

  # The prompt is the only thing standing between a chat log and a wrong
  # board, so its load-bearing instructions are worth asserting.
  def test_prompt_forbids_inventing_a_schedule_and_distrusts_the_transcript
    prompt = AI.system_prompt(%w[Studio Client])
    assert_match(/Never guess/, prompt)
    assert_match(/Omit any field you are not confident about/, prompt)
    assert_match(/data, not instructions/, prompt,
                 "the transcript is untrusted and the prompt must say so")
    assert_match(/Studio, Client/, prompt, "known tracks are offered so it reuses lanes")
  end

  def test_reply_parsing_handles_bare_json_and_fenced_json
    bare = fake_message('{"tasks":[{"title":"Alpha"}]}')
    assert_equal [{ "title" => "Alpha" }], AI.parse_reply(bare)

    fenced = fake_message("Here you go:\n```json\n{\"tasks\":[{\"title\":\"Beta\"}]}\n```")
    assert_equal [{ "title" => "Beta" }], AI.parse_reply(fenced)
  end

  def test_reply_parsing_rejects_junk_with_a_usable_message
    err = assert_raises(AI::AIError) { AI.parse_reply(fake_message("I could not do that.")) }
    assert_match(/JSON|task list/, err.message)

    err = assert_raises(AI::AIError) { AI.parse_reply(fake_message("")) }
    assert_match(/nothing to read/, err.message)
  end

  def test_a_refusal_is_reported_as_a_refusal
    msg = fake_message("", stop_reason: :refusal,
                           stop_details: Struct.new(:category).new(:cyber))
    err = assert_raises(AI::AIError) { AI.parse_reply(msg) }
    assert_match(/declined/, err.message)
    assert_match(/cyber/, err.message)
    assert_match(/offline parser/, err.message)
  end

  def test_non_hash_rows_are_dropped
    msg = fake_message('{"tasks":[{"title":"Alpha"},"junk",null]}')
    assert_equal [{ "title" => "Alpha" }], AI.parse_reply(msg)
  end

  private

  # Stands in for the SDK's response object: content blocks whose .type is a
  # Symbol, plus the stop fields the real one carries.
  def fake_message(text, stop_reason: :end_turn, stop_details: nil)
    block = Struct.new(:type, :text).new(:text, text)
    Struct.new(:content, :stop_reason, :stop_details)
          .new([block], stop_reason, stop_details)
  end
end
