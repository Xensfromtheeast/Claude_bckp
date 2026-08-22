# frozen_string_literal: true

module MissionControlDashboard
  # Turns a shared AI chat — exported or pasted as markdown — into candidate
  # tasks, using nothing but the standard library.
  #
  # This is the offline half of chat import, and it is the DEFAULT half. A
  # conversation where you worked out what to do next already contains the
  # tasks in a recognisable shape: checkbox lines, action-item bullets,
  # numbered plans under a "next steps" heading. Reading those needs pattern
  # matching, not a language model, so the feature works on a train with no
  # signal and costs nothing.
  #
  # It proposes; it never writes. Everything it finds lands in the review
  # queue (see Proposals) for you to accept, edit or discard.
  #
  # The text being parsed is UNTRUSTED — it came from a chat log someone
  # else may have written. Nothing here interprets it as instructions: it is
  # only ever scanned for patterns and copied into strings that a human
  # reads before anything reaches the board.
  class Importer
    # Headings that mean "what follows is work", not prose.
    ACTION_HEADING = /
      \b(action\s+items?|next\s+steps?|to-?dos?|tasks?|plan|
         deliverables?|follow[\s-]?ups?|this\s+week|homework)\b
    /xi.freeze

    # "- [ ] thing" / "* [x] thing"
    CHECKBOX = /\A\s*[-*+]\s*\[( |x|X)\]\s*(.+)\z/.freeze
    BULLET   = %r{\A\s*(?:[-*+]|\d+[.)])\s+(.+)\z}.freeze
    HEADING  = /\A\s*(#{'#'}{1,6})\s+(.+?)\s*#*\z/.freeze

    # Lines that are clearly the model talking, not a task.
    CHATTER = /
      \A(sure|certainly|great|here(?:'s| is)|i(?:'ll| will| can| have)|
         let\s+me|of\s+course|absolutely|happy\s+to|hope\s+this|
         would\s+you|does\s+that|note\s+that|in\s+summary|to\s+summari[sz]e)\b
    /xi.freeze

    DAYS = %w[mon tue wed thu fri sat sun].freeze
    # Longest alternatives first, so "tues" is not eaten as "tue".
    DAY_NAMES = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|" \
                "tomorrow|today|tues|thurs|thur|weds|mon|tue|wed|thu|fri|sat|sun"
    DAY_WORDS = /\b(#{DAY_NAMES})\b/i.freeze
    TIME_WORDS = /\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b/i.freeze
    # No \b before the unit: in "5h" there is no boundary between 5 and h.
    HOURS_WORDS = /(\d+(?:\.\d+)?)\s*(?:hrs|hr|hours|hour|h)\b/i.freeze
    MINS_WORDS  = /(\d{1,3})\s*(?:minutes|mins|min|m)\b/i.freeze

    # "(5h)", "(30 mins)" — a size in brackets is never part of the name.
    SIZE_PAREN = /\s*\([^()]*\d+(?:\.\d+)?\s*(?:hrs|hr|hours|hour|h|minutes|mins|min|m)\b[^()]*\)/i.freeze
    # "by Friday 2pm", "on Thursday", or a bare trailing "Wednesday 10am".
    WHEN_TAIL = /\s*[-—–,;]?\s*(?:\b(?:by|before|due|on|at|this|next)\b\s+)?
                 \b(?:#{DAY_NAMES})\b
                 (?:\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?/xi.freeze

    # Lifting "Thursday 9am" out of "Master bus pass Thursday 9am — needs 4
    # hours" leaves "— needs" hanging off the end. Trim the connectors that
    # only existed to introduce the time we just removed.
    DANGLING = /[\s,;:.–—-]*\b(?:for|by|on|at|in|of|due|needs?|takes?|about|around|
                   this|next|and|then|to|with|before|until|till|est|approx)\b
                [\s,;:.–—-]*\z/xi.freeze

    # A chat export can be enormous; a board cannot. Read a bounded prefix
    # and say so rather than chewing through a 40MB transcript.
    MAX_BYTES = 512 * 1024
    MAX_TASKS = 60

    attr_reader :warnings

    def initialize(default_track: "Inbox")
      @default_track = default_track
      @warnings = []
    end

    # Returns an array of candidate task hashes (board schema + provenance).
    def parse(text, source: "chat")
      @warnings = []
      body = clamp(text.to_s)
      lines = body.lines.map { |l| l.chomp.rstrip }

      found = []
      in_action = false

      lines.each_with_index do |line, i|
        if (m = HEADING.match(line))
          in_action = ACTION_HEADING.match?(m[2])
          next
        end

        # A blank line does not close an action section — lists are often
        # spaced out — but a paragraph of prose does.
        in_action = false if in_action && prose?(line)

        if (m = CHECKBOX.match(line))
          found << build(m[2], done: m[1].downcase == "x", source: source, line: i + 1)
          next
        end

        next unless in_action
        next unless (m = BULLET.match(line))

        text_ = m[1]
        next if CHATTER.match?(text_)

        found << build(text_, done: false, source: source, line: i + 1)
      end

      dedup(found).first(MAX_TASKS).tap do |list|
        @warnings << "Found nothing that looks like a task. Checklists " \
                     "(\"- [ ] ...\") and bullets under an \"Action items\" or " \
                     "\"Next steps\" heading are what this reads." if list.empty?
        @warnings << "Stopped at #{MAX_TASKS} candidates; there were more." if found.length > MAX_TASKS
      end
    end

    private

    def clamp(text)
      return text if text.bytesize <= MAX_BYTES

      @warnings << "Chat was larger than #{MAX_BYTES / 1024}KB; read the first part only."
      text.byteslice(0, MAX_BYTES).scrub("")
    end

    # Sentence-shaped and long: prose, not a list item.
    def prose?(line)
      s = line.strip
      return false if s.empty?
      return false if BULLET.match?(line) || CHECKBOX.match?(line)

      s.length > 60 && s.match?(/[.!?]\s|\A\w+[^:]*[.!?]\z/)
    end

    def build(raw, done:, source:, line:)
      text = raw.to_s.strip
      text = text.sub(/\A\*\*(.+?)\*\*\s*[:-]?\s*/) { Regexp.last_match(1) + " " } # **Bold:** lead-in
      text = text.gsub(/`([^`]*)`/, '\1').strip

      hints = time_hints(text)
      title = clean_title(text)

      task = {
        "title"  => title,
        "track"  => @default_track,
        "status" => done ? "done" : "todo",
        "source" => source.to_s,
        "line"   => line,
        "evidence" => text[0, 300]
      }
      task["start"] = hints[:start] if hints[:start]
      task["effort"] = hints[:hours] if hints[:hours]
      task["duration"] = hints[:hours] if hints[:hours]
      task
    end

    # Strip the scheduling language out of the title — it is captured in the
    # fields now, and "Mix Ep.14 by Friday 2pm (3h)" is a worse task name
    # than "Mix Ep.14".
    def clean_title(text)
      t = text.dup
      t = t.gsub(SIZE_PAREN, " ")
      t = t.gsub(WHEN_TAIL, " ")
      t = t.gsub(HOURS_WORDS, " ")
      t = t.gsub(MINS_WORDS, " ")
      t = t.gsub(/\s{2,}/, " ").strip
      t = t.sub(/[\s,;:–—-]+\z/, "").sub(/\A[\s,;:–—-]+/, "")
      4.times do
        trimmed = t.sub(DANGLING, "")
        break if trimmed == t

        t = trimmed
      end
      t = text.strip if t.empty?
      t[0, 120]
    end

    def time_hints(text)
      out = {}

      if (d = DAY_WORDS.match(text))
        day = normalize_day(d[1].downcase)
        time = clock(text)
        out[:start] = time ? "#{day} #{time}" : day if day
      end

      if (h = HOURS_WORDS.match(text))
        out[:hours] = h[1].to_f
      elsif (m = MINS_WORDS.match(text))
        mins = m[1].to_i
        out[:hours] = (mins / 60.0).round(2) if mins.positive?
      end
      out[:hours] = nil if out[:hours] && out[:hours] <= 0
      out.compact
    end

    def normalize_day(word)
      return word if %w[today tomorrow].include?(word)

      key = word[0, 3]
      DAYS.include?(key) ? key : nil
    end

    def clock(text)
      m = TIME_WORDS.match(text)
      return nil unless m

      if m[3] # 9am / 2:30pm
        h = m[1].to_i
        mins = m[2].to_i
        h += 12 if m[3].downcase == "pm" && h < 12
        h = 0 if m[3].downcase == "am" && h == 12
      else # 14:30
        h = m[4].to_i
        mins = m[5].to_i
      end
      return nil if h > 23 || mins > 59

      format("%02d:%02d", h, mins)
    end

    # The same action often appears in a chat more than once — as a plan and
    # then as a recap. Keep the richer copy.
    def dedup(list)
      by_key = {}
      list.each do |t|
        key = t["title"].downcase.gsub(/[^a-z0-9]+/, " ").strip
        next if key.empty?

        prev = by_key[key]
        by_key[key] = prev.nil? || t.length > prev.length ? t : prev
      end
      by_key.values
    end
  end
end
