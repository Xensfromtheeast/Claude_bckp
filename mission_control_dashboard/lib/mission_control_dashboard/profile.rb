# frozen_string_literal: true

require "yaml"
require "fileutils"

module MissionControlDashboard
  # Who the board is for. A profile.yml next to board.yml, plain and
  # human-edited like everything else here, entirely local — nothing in it
  # ever leaves the machine.
  #
  # The capacity tile can already say whether a week is arithmetically
  # possible. It cannot say whether the plan fits the person: what their
  # tracks actually mean, how many hours a week really holds for them,
  # what they habitually slip on. A profile carries that context, and the
  # dashboard turns it into warnings in the existing warning box — advice
  # surfaced, never tasks rejected.
  #
  # The seed template ships fully commented out on purpose: every field is
  # a statement about the operator, so the operator writes it. Until they
  # do, the profile is "not set" and changes nothing.
  class Profile
    attr_reader :path

    def self.default_path(board_path)
      File.join(File.dirname(File.expand_path(board_path)), "profile.yml")
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def exist?
      File.exist?(@path)
    end

    # Writes the commented template. Returns true if it wrote.
    def install_seed(force: false)
      return false if exist? && !force

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, SEED_PROFILE, encoding: "UTF-8")
      true
    end

    # {} when absent, empty, or unreadable — a broken profile must never
    # take the dashboard down with it.
    def data
      return {} unless exist?

      doc = YAML.safe_load(File.read(@path, encoding: "UTF-8"), aliases: true)
      doc.is_a?(Hash) ? doc.transform_keys(&:to_s) : {}
    rescue Psych::SyntaxError
      {}
    end

    # What the UI needs to know, without shipping the whole document into
    # every board payload.
    def summary
      d = data
      {
        "set"          => !d.empty?,
        "path"         => @path,
        "operator"     => d["operator"].to_s,
        "focus_tracks" => track_list(d),
        "weekly_hours" => positive_hours(d["weekly_hours"])
      }
    end

    # Alignment checks against a computed board snapshot. Returns warning
    # strings for the existing warnings box; empty when the profile is not
    # set or nothing is off.
    def review(snapshot)
      d = data
      return [] if d.empty?

      out = []
      out.concat(capacity_warning(d, snapshot))
      out.concat(focus_warning(d, snapshot))
      out
    end

    private

    def capacity_warning(d, snapshot)
      cap = positive_hours(d["weekly_hours"])
      return [] unless cap

      booked = snapshot.dig("stats", "hours_booked").to_f
      return [] unless booked > cap

      ["Booked #{booked.round(1)}h against the #{format_hours(cap)}h week declared in profile.yml — " \
       "cut #{(booked - cap).round(1)}h or the plan overruns the person, not just the goal."]
    end

    def focus_warning(d, snapshot)
      focus = track_list(d)
      return [] if focus.empty?

      keys = focus.map(&:downcase)
      off = Array(snapshot["tasks"]).reject { |t| t["status"] == "done" }
                                    .reject { |t| keys.include?(t["track"].to_s.downcase) }
      hours = off.sum { |t| t["effort"].to_f * (1.0 - t["progress"].to_f) }
      return [] if hours < 1

      names = off.map { |t| t["title"] }.first(3).join(", ")
      more  = off.length > 3 ? ", …" : ""
      ["#{hours.round(1)}h of open work sits outside your focus tracks " \
       "(#{focus.join(', ')}): #{names}#{more}."]
    end

    def track_list(d)
      Array(d["focus_tracks"]).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def positive_hours(value)
      f = Float(value.to_s)
      f.positive? ? f : nil
    rescue ArgumentError
      nil
    end

    def format_hours(f)
      f == f.to_i ? f.to_i : f
    end

    SEED_PROFILE = <<~YAML
      # ~/.mission_control/profile.yml — who this board is for.
      #
      # Entirely optional, entirely local: nothing here is sent anywhere,
      # and until you uncomment a field the dashboard behaves exactly as
      # before. Each field you do set turns into context the dashboard can
      # check your week against — warnings in the warning box, never
      # rejected tasks.
      #
      # Uncomment and fill in what is true. Delete what isn't yours.

      # operator: Xens

      # What your tracks actually mean — for the human reading the board,
      # and for anything that later proposes tasks on your behalf.
      # work:
      #   Client: paid deliverables and the meetings that guard them
      #   Studio: audio production — mixing, VO, radio automation
      #   Ops: the systems that keep everything else standing

      # The hours a week actually holds for you, after life happens.
      # If the board books more than this, the dashboard says so — the
      # day_start/day_end window says what is possible, this says what
      # is sustainable.
      # weekly_hours: 45

      # Tracks this season is actually pointed at. Open work outside
      # them gets flagged (not blocked) so drift is visible while it is
      # still cheap to correct.
      # focus_tracks:
      #   - Client
      #   - Studio

      # Standing commitments that compete for the same hours the capacity
      # check counts. Free text — these are for the reader, and for
      # anything that later helps plan a week.
      # constraints:
      #   - School run weekday mornings until 08:30
      #   - No sessions after 21:00

      # Known failure modes — patterns worth flagging, not moralising.
      # vices:
      #   - Saying yes to new client work before scoping it
      #   - Rebuilding tooling instead of shipping with what exists

      # What to route work toward when there is a choice.
      # strengths:
      #   - Live sound under pressure
      #   - Client-facing narration and pitch
    YAML
  end
end
