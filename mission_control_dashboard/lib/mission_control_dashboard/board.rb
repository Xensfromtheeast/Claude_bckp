# frozen_string_literal: true

require "yaml"
require "time"
require "date"
require "fileutils"

require_relative "seed"

module MissionControlDashboard
  # Loads the YAML board, resolves relative times against the week being
  # viewed, and derives everything the dashboard shows: live tasks, the
  # goal countdown, and whether the booked work actually fits in the hours
  # left before that goal.
  class Board
    STATUSES = %w[todo in_progress blocked done].freeze
    DAY_KEYS = { "mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4,
                 "fri" => 5, "sat" => 6, "sun" => 7 }.freeze

    class BoardError < StandardError; end

    attr_reader :path, :warnings

    def self.default_path
      env = ENV["MISSION_CONTROL_BOARD"]
      return File.expand_path(env) if env && !env.empty?

      File.join(Dir.home, ".mission_control", "board.yml")
    end

    # Writes the seed board. Returns true if it wrote, false if it existed.
    def self.install_seed(path = default_path, force: false)
      path = File.expand_path(path)
      return false if File.exist?(path) && !force

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, SEED_BOARD, encoding: "UTF-8")
      true
    end

    def initialize(path = self.class.default_path)
      @path = File.expand_path(path)
      @warnings = []
    end

    # Can the time parser make sense of this string? Used by the editor to
    # reject a typo at save time instead of silently dropping the task later.
    def readable_time?(value)
      !parse_time(value, start_of_week(Time.now)).nil?
    end

    # Re-reads the file on every call, so editing the YAML and hitting
    # refresh is the entire edit loop. No restart, no rebuild.
    def load!
      @warnings = []
      self.class.install_seed(@path)

      # Always UTF-8. Ruby's default external encoding is *not* UTF-8 on
      # Windows, so a board containing an em-dash or an accented client name
      # would blow up with Encoding::CompatibilityError on read.
      raw = File.read(@path, encoding: "UTF-8")
      doc = YAML.safe_load(
        raw,
        permitted_classes: [Date, Time, DateTime],
        aliases: true
      )
      doc = {} if doc.nil? || doc == false
      raise BoardError, "board.yml must be a YAML mapping, got #{doc.class}" unless doc.is_a?(Hash)

      doc
    rescue Psych::SyntaxError => e
      raise BoardError, "board.yml is not valid YAML (line #{e.line}): #{e.problem}"
    rescue Errno::ENOENT
      raise BoardError, "board file not found at #{@path}"
    end

    # The full payload the UI renders from.
    def snapshot(now: Time.now, week_offset: 0)
      doc  = load!
      meta = stringify(doc["meta"])
      week_start = start_of_week(now) + (week_offset * 7 * 86_400)

      day_start_min = minutes_of(meta["day_start"], 7 * 60)
      day_end_min   = minutes_of(meta["day_end"], 22 * 60)
      if day_end_min <= day_start_min
        @warnings << "day_end (#{meta['day_end']}) is not after day_start (#{meta['day_start']}); falling back to 07:00-22:00."
        day_start_min = 7 * 60
        day_end_min   = 22 * 60
      end

      tasks = build_tasks(doc["tasks"], week_start, now, day_start_min, day_end_min)
      goal  = build_goal(doc["goal"], week_start, now, tasks, day_start_min, day_end_min)

      {
        "meta" => {
          "title"      => meta["title"] || "Mission Control",
          "operator"   => meta["operator"].to_s,
          "version"    => VERSION,
          "board_path" => @path,
          "day_start"  => day_start_min,
          "day_end"    => day_end_min,
          "compress"   => meta.key?("compress") ? !!meta["compress"] : true,
          "week_start" => iso(week_start),
          "week_end"   => iso(week_start + (7 * 86_400)),
          "week_offset" => week_offset,
          "now"        => iso(now),
          "generated"  => iso(now)
        },
        "goal"     => goal,
        "tasks"    => tasks,
        "tracks"   => tracks_for(tasks),
        "stats"    => stats_for(tasks, now),
        "warnings" => @warnings
      }
    end

    private

    # ---------- tasks ----------

    def build_tasks(list, week_start, now, day_start_min = 0, day_end_min = 1440)
      return [] unless list.is_a?(Array)

      outside = []

      list.each_with_index.filter_map do |row, idx|
        unless row.is_a?(Hash)
          @warnings << "tasks[#{idx}] is not a mapping; skipped."
          next
        end

        t     = stringify(row)
        title = (t["title"] || t["name"] || t["id"]).to_s
        if title.empty?
          @warnings << "tasks[#{idx}] has no title; skipped."
          next
        end

        start = parse_time(t["start"] || t["begin"], week_start)
        unless start
          @warnings << "#{title.inspect}: could not read start #{t['start'].inspect}; skipped."
          next
        end

        finish = parse_time(t["end"] || t["finish"], week_start)
        if finish.nil?
          hours  = to_f_or_nil(t["duration"] || t["hours"]) || 1.0
          hours  = 0.25 if hours <= 0
          finish = start + (hours * 3600)
        end

        if finish <= start
          @warnings << "#{title.inspect}: end is not after start; padded to 15 minutes."
          finish = start + 900
        end

        status = normalize_status(t["status"], title)

        # A DONE task pinned to a date outside the viewed week belongs to
        # its own week (and to the archive), not to every week after it as
        # a sliver on the edge of the chart. Open work is different: a
        # pinned task you never finished is still an obligation, so it
        # stays visible — and counted — wherever you are.
        next if status == "done" &&
                (finish <= week_start || start >= week_start + (7 * 86_400))

        checklist = build_checklist(t["checklist"] || t["subtasks"], title)
        prog      = progress_for(t["progress"], status, checklist)

        # `duration` is the window the work lives in; `effort` is how many
        # hours it actually costs you. For a project that is "open Mon->Fri"
        # but only takes 8 hours, those are very different numbers, and only
        # the second one belongs in a capacity calculation.
        span_hours = (finish - start) / 3600.0
        effort     = to_f_or_nil(t["effort"])
        if effort && effort.negative?
          @warnings << "#{title.inspect}: effort cannot be negative; ignored."
          effort = nil
        end

        # A task scheduled outside day_start..day_end gets squashed against
        # the edge of its column in "work hours" view. Say so rather than
        # letting it silently render as a 4px sliver.
        clipped = outside_window?(start, finish, day_start_min, day_end_min)
        outside << title if clipped

        {
          "clipped" => clipped,
          "id"       => (t["id"] || "t#{idx}").to_s,
          "title"    => title,
          "track"    => (t["track"] || t["lane"] || "General").to_s,
          "owner"    => t["owner"].to_s,
          "notes"    => t["notes"].to_s,
          "status"   => status,
          "progress" => prog,
          "checklist" => checklist,
          "start"    => iso(start),
          "end"      => iso(finish),
          # The strings as written in the file. The editor needs these to
          # tell a weekday-relative task from one pinned to a real date —
          # otherwise editing a pinned task silently converts it to
          # relative and it starts drifting week to week.
          "raw_start" => (t["start"] || t["begin"]).to_s,
          "raw_end"   => (t["end"] || t["finish"]).to_s,
          "start_ms" => (start.to_f * 1000).round,
          "end_ms"   => (finish.to_f * 1000).round,
          "hours"    => span_hours.round(2),
          "effort"   => (effort || span_hours).round(2),
          "spanning" => !effort.nil? && effort < span_hours - 0.01,
          "state"    => state_of(start, finish, status, now)
        }
      end.tap do
        unless outside.empty?
          @warnings << "Outside your #{fmt_min(day_start_min)}-#{fmt_min(day_end_min)} window, so squashed " \
                       "in 'work hours' view: #{outside.join(', ')}. Widen meta.day_start/day_end, " \
                       "set meta.compress: false, or click '7 days'."
        end
      end
    end

    # Only the ENDPOINTS can sit outside the drawn window. A Mon->Fri project
    # is not "outside working hours" just because it spans four nights, so
    # cumulative elapsed minutes is the wrong measure here.
    def outside_window?(start, finish, day_start_min, day_end_min)
      s_min = (start.hour * 60) + start.min
      e_min = (finish.hour * 60) + finish.min
      same_day = start.strftime("%F") == finish.strftime("%F")

      return true if s_min < day_start_min
      return e_min > day_end_min if same_day

      # Multi-day: the finish time must also land inside a drawn column.
      e_min > day_end_min || e_min < day_start_min
    end

    def fmt_min(minutes)
      format("%02d:%02d", minutes / 60, minutes % 60)
    end

    def normalize_status(value, title)
      s = value.to_s.strip.downcase.tr(" -", "__")
      s = "in_progress" if %w[wip doing active running].include?(s)
      s = "done" if %w[complete completed finished shipped].include?(s)
      s = "blocked" if %w[block stuck waiting].include?(s)
      s = "todo" if s.empty? || %w[pending not_started backlog].include?(s)
      unless STATUSES.include?(s)
        @warnings << "#{title.inspect}: unknown status #{value.inspect}; treated as todo."
        s = "todo"
      end
      s
    end

    def progress_for(value, status, checklist = [])
      return 1.0 if status == "done"

      p = to_f_or_nil(value)

      # An explicit number wins. Otherwise a checklist gives us *measured*
      # progress - ticked items over total - instead of a felt percentage.
      if p.nil? && !checklist.empty?
        return (checklist.count { |i| i["done"] } / checklist.length.to_f).round(3)
      end
      return status == "in_progress" ? 0.5 : 0.0 if p.nil?

      p /= 100.0 if p > 1.0 # tolerate "60" meaning 60%
      p.clamp(0.0, 1.0).round(3)
    end

    # Accepts either a bare string ("Finalize Contract") or a mapping
    # ({title: Finalize Contract, done: true}). Strings are unchecked;
    # a leading "x " or "[x] " also marks an item done.
    def build_checklist(raw, title)
      return [] if raw.nil?
      unless raw.is_a?(Array)
        @warnings << "#{title.inspect}: checklist must be a list; ignored."
        return []
      end

      raw.filter_map do |item|
        case item
        when String
          text = item.strip
          done = !!text.sub!(/\A(\[x\]|x)\s+/i, "")
          text.empty? ? nil : { "title" => text, "done" => done }
        when Hash
          h = stringify(item)
          text = (h["title"] || h["name"] || h["label"]).to_s.strip
          next if text.empty?

          { "title" => text, "done" => truthy?(h["done"] || h["checked"] || h["complete"]) }
        end
      end
    end

    def truthy?(value)
      return false if value.nil?
      return value if [true, false].include?(value)

      %w[true yes y 1 done].include?(value.to_s.strip.downcase)
    end

    # done | live | overdue | blocked | upcoming
    #
    # An explicit status beats the clock: if you have marked something
    # in_progress it is live even when its scheduled window has not opened
    # yet, because you are the one doing the work, not the calendar.
    def state_of(start, finish, status, now)
      return "done" if status == "done"
      return "blocked" if status == "blocked"
      return "overdue" if finish < now
      return "live" if status == "in_progress"
      return "live" if start <= now && now <= finish

      "upcoming"
    end

    def tracks_for(tasks)
      tasks.map { |t| t["track"] }.uniq
    end

    # ---------- goal ----------

    def build_goal(raw, week_start, now, tasks, day_start_min, day_end_min)
      g = stringify(raw)
      label = (g["label"] || g["title"] || "").to_s
      due   = parse_time(g["due"] || g["deadline"] || g["date"], week_start)

      unless label.empty? || due
        @warnings << "goal.due #{(g['due'] || g['deadline']).inspect} could not be read; countdown disabled."
      end
      return { "set" => false } if label.empty? || due.nil?

      open_tasks = tasks.reject { |t| t["status"] == "done" }
      # Hours of work still on the books, discounted by declared progress.
      # Uses `effort` where given, so a project that stays open all week but
      # only costs 8 hours is counted as 8 hours, not 40.
      work_left = open_tasks.sum { |t| t["effort"] * (1.0 - t["progress"]) }
      capacity  = working_hours_between(now, due, day_start_min, day_end_min)
      done      = tasks.count { |t| t["status"] == "done" }

      {
        "set"            => true,
        "label"          => label,
        "detail"         => g["detail"].to_s,
        "due"            => iso(due),
        "due_ms"         => (due.to_f * 1000).round,
        "seconds_left"   => (due - now).round,
        "passed"         => due < now,
        "tasks_total"    => tasks.length,
        "tasks_done"     => done,
        "tasks_open"     => open_tasks.length,
        "work_left"      => work_left.round(2),
        "capacity"       => capacity.round(2),
        "slack"          => (capacity - work_left).round(2),
        "at_risk"        => work_left > capacity,
        "load"           => capacity <= 0 ? nil : (work_left / capacity).round(3),
        "blocked"        => tasks.count { |t| t["status"] == "blocked" },
        "overdue"        => tasks.count { |t| t["state"] == "overdue" }
      }
    end

    # Working hours between two moments, counting only the day_start..day_end
    # window on each day. This is what turns a countdown into a capacity check.
    def working_hours_between(from, to, day_start_min, day_end_min)
      return 0.0 if to <= from

      total = 0.0
      cursor = Time.new(from.year, from.month, from.day)
      guard = 0
      while cursor < to && guard < 400
        guard += 1
        win_open  = cursor + (day_start_min * 60)
        win_close = cursor + (day_end_min * 60)
        lo = [win_open, from].max
        hi = [win_close, to].min
        total += (hi - lo) / 3600.0 if hi > lo
        cursor += 86_400
      end
      total
    end

    # ---------- stats ----------

    def stats_for(tasks, now)
      booked = tasks.sum { |t| t["effort"] }
      {
        "total"       => tasks.length,
        "done"        => tasks.count { |t| t["status"] == "done" },
        "live"        => tasks.count { |t| t["state"] == "live" },
        "blocked"     => tasks.count { |t| t["state"] == "blocked" },
        "overdue"     => tasks.count { |t| t["state"] == "overdue" },
        "upcoming"    => tasks.count { |t| t["state"] == "upcoming" },
        "hours_booked" => booked.round(2),
        "hours_done"  => tasks.sum { |t| t["effort"] * t["progress"] }.round(2)
      }
    end

    # ---------- time plumbing ----------

    # Monday 00:00 of the week containing `time`.
    def start_of_week(time)
      midnight = Time.new(time.year, time.month, time.day)
      back = (midnight.wday - 1) % 7 # Ruby wday: Sunday == 0
      midnight - (back * 86_400)
    end

    # Accepts Time/Date from YAML, "HH:MM" offsets from a weekday keyword,
    # or an absolute "YYYY-MM-DD HH:MM".
    def parse_time(value, week_start)
      case value
      when nil          then nil
      when Time         then value
      when DateTime     then value.to_time
      when Date         then Time.new(value.year, value.month, value.day)
      when Numeric      then Time.at(value)
      when String       then parse_time_string(value.strip, week_start)
      else nil
      end
    end

    def parse_time_string(str, week_start)
      return nil if str.empty?

      lower = str.downcase

      if (m = lower.match(/\A(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?\s*(.*)\z/))
        day = DAY_KEYS[m[1]]
        return week_start + ((day - 1) * 86_400) + (minutes_of(m[2], 9 * 60) * 60)
      end

      if (m = lower.match(/\A(today|tomorrow|yesterday)\s*(.*)\z/))
        base = Time.now
        shift = { "today" => 0, "tomorrow" => 1, "yesterday" => -1 }[m[1]]
        midnight = Time.new(base.year, base.month, base.day) + (shift * 86_400)
        return midnight + (minutes_of(m[2], 9 * 60) * 60)
      end

      begin
        Time.parse(str)
      rescue ArgumentError, TypeError
        nil
      end
    end

    # "14:30" -> 870. Also tolerates "2:30pm", "9", "0930".
    def minutes_of(value, fallback)
      return fallback if value.nil?
      return (value * 60).round if value.is_a?(Numeric)

      s = value.to_s.strip.downcase
      return fallback if s.empty?

      pm = s.include?("pm")
      am = s.include?("am")
      s  = s.gsub(/[ap]m/, "").strip

      if (m = s.match(/\A(\d{1,2}):(\d{2})\z/))
        h = m[1].to_i
        mi = m[2].to_i
      elsif (m = s.match(/\A(\d{1,2})(\d{2})\z/))
        h = m[1].to_i
        mi = m[2].to_i
      elsif (m = s.match(/\A(\d{1,2})\z/))
        h = m[1].to_i
        mi = 0
      else
        return fallback
      end

      h += 12 if pm && h < 12
      h = 0 if am && h == 12
      return fallback if h > 23 || mi > 59

      (h * 60) + mi
    end

    def iso(time)
      time.strftime("%Y-%m-%dT%H:%M:%S%:z")
    end

    def to_f_or_nil(value)
      return nil if value.nil?
      return value.to_f if value.is_a?(Numeric)

      s = value.to_s.strip
      return nil if s.empty?

      Float(s)
    rescue ArgumentError
      nil
    end

    def stringify(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end
end
