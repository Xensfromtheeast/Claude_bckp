# frozen_string_literal: true

require "yaml"
require "fileutils"
require "digest"

module MissionControlDashboard
  # Edits board.yml *surgically*.
  #
  # The naive implementation of "save from the UI" is YAML.load then YAML.dump,
  # which silently destroys every comment in the file. That is unacceptable
  # here: a board is a document people annotate ("<-- ESTIMATE", "waiting on
  # their IT"), and losing those annotations on first save would make the
  # editor worse than a text editor.
  #
  # So this rewrites only the exact line range of the task you touched and
  # leaves every other byte of the file alone. Comments between tasks, the
  # header block, the trailing notes: all preserved.
  #
  # The one thing it cannot preserve is an inline comment on a key inside a
  # task you just edited, because that task's block is regenerated. Comments
  # on untouched tasks are safe.
  class Writer
    class ConflictError < StandardError; end
    class WriteError < StandardError; end

    # Order keys are emitted in, so hand-written and UI-written tasks look
    # the same rather than the UI producing alphabetised soup.
    KEY_ORDER = %w[id title track start end duration effort status progress owner notes].freeze
    EDITABLE  = (KEY_ORDER + %w[checklist]).freeze

    attr_reader :path

    def initialize(path)
      @path = File.expand_path(path)
    end

    # Opaque token identifying the file's current state. The browser echoes it
    # back on save; a mismatch means someone (you, in a text editor, or another
    # tab) changed the file underneath and we refuse rather than clobber.
    def revision
      return "absent" unless File.exist?(@path)

      stat = File.stat(@path)
      Digest::SHA256.hexdigest("#{stat.mtime.to_f}-#{stat.size}")[0, 16]
    end

    def add_task(attrs, rev: nil)
      mutate(rev) do |lines, items, _doc|
        block = render_task(attrs, item_indent(lines, items))
        if items.empty?
          insert_first_task(lines, block)
        else
          last = items.last
          lines.insert(last[:end] + 1, *block)
        end
        attrs["id"]
      end
    end

    def update_task(id, attrs, rev: nil)
      mutate(rev) do |lines, items, doc|
        i = index_of(id, items, doc)
        raise WriteError, "no task with id #{id.inspect}" if i.nil?

        item = items[i]
        merged = (doc.dig("tasks", i) || {}).transform_keys(&:to_s)
        attrs.each { |k, v| v.nil? ? merged.delete(k) : merged[k] = v }
        merged["id"] ||= id

        block = render_task(merged, item[:indent])
        lines[item[:start]..item[:end]] = block
        merged["id"]
      end
    end

    def delete_task(id, rev: nil)
      mutate(rev) do |lines, items, doc|
        i = index_of(id, items, doc)
        raise WriteError, "no task with id #{id.inspect}" if i.nil?

        item = items[i]
        lines[item[:start]..item[:end]] = []
        id
      end
    end

    private

    # ---------- the write cycle ----------

    def mutate(rev)
      raise WriteError, "board file does not exist: #{@path}" unless File.exist?(@path)

      current = revision
      if rev && !rev.empty? && rev != current
        raise ConflictError,
              "the board file changed since this page loaded (someone edited it in a text editor, " \
              "or another tab saved). Refresh to pick up those changes, then try again."
      end

      src   = File.read(@path, encoding: "UTF-8")
      lines = src.lines.map { |l| l.chomp("\n") }
      doc   = YAML.safe_load(src, permitted_classes: [Date, Time, DateTime], aliases: true) || {}
      raise WriteError, "board.yml is not a YAML mapping" unless doc.is_a?(Hash)

      items  = task_line_ranges(src, lines)
      result = yield(lines, items, doc)

      body = lines.join("\n")
      body += "\n" unless body.end_with?("\n")

      # Never hand back a file we just corrupted.
      begin
        check = YAML.safe_load(body, permitted_classes: [Date, Time, DateTime], aliases: true)
        raise WriteError, "refusing to save: result is not a mapping" unless check.is_a?(Hash)
      rescue Psych::SyntaxError => e
        raise WriteError, "refusing to save: the edit would produce invalid YAML (#{e.problem})"
      end

      atomic_write(body)
      { "id" => result, "rev" => revision }
    end

    def atomic_write(body)
      FileUtils.cp(@path, "#{@path}.bak") if File.exist?(@path)
      tmp = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp, body, encoding: "UTF-8")
      File.rename(tmp, @path) # atomic on the same filesystem
    ensure
      begin
        File.unlink(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        nil
      end
    end

    # ---------- locating tasks in the raw text ----------

    # Returns [{start:, end:, indent:}] — 0-indexed, inclusive line ranges
    # covering each entry of the `tasks:` sequence.
    def task_line_ranges(src, lines)
      seq = nil
      begin
        root = Psych.parse(src)&.root
        return [] unless root.is_a?(Psych::Nodes::Mapping)

        root.children.each_slice(2) do |k, v|
          seq = v if k.respond_to?(:value) && k.value == "tasks"
        end
      rescue Psych::SyntaxError
        return []
      end
      return [] unless seq.is_a?(Psych::Nodes::Sequence) && !seq.children.empty?

      starts = seq.children.map(&:start_line)
      limit  = sequence_limit(lines, starts.first)

      starts.each_with_index.map do |start, i|
        upper = (i + 1 < starts.length ? starts[i + 1] - 1 : limit)
        { start: start, end: trim_trailing(lines, start, upper),
          indent: lines[start][/\A\s*/].length }
      end
    end

    # Last line belonging to the sequence: scan forward until a non-blank,
    # non-comment line appears at or left of the sequence's own indentation.
    def sequence_limit(lines, first_start)
      indent = lines[first_start][/\A\s*/].length
      idx    = first_start
      ((first_start + 1)...lines.length).each do |n|
        line = lines[n]
        next if line.strip.empty?

        here = line[/\A\s*/].length
        break if here < indent || (here == indent && !line.lstrip.start_with?("-", "#"))

        idx = n
      end
      idx
    end

    # Walk back over blank lines and comments so they stay attached to the
    # gap between tasks rather than being swallowed by the task above.
    def trim_trailing(lines, lower, upper)
      n = [upper, lines.length - 1].min
      n -= 1 while n > lower && (lines[n].strip.empty? || lines[n].lstrip.start_with?("#"))
      n
    end

    def index_of(id, items, doc)
      rows = doc["tasks"]
      return nil unless rows.is_a?(Array)

      found = rows.each_with_index.find do |row, idx|
        next false unless row.is_a?(Hash)

        explicit = (row["id"] || row[:id]).to_s
        (explicit.empty? ? "t#{idx}" : explicit) == id.to_s
      end
      i = found&.last
      i && i < items.length ? i : nil
    end

    def item_indent(lines, items)
      return items.first[:indent] unless items.empty?

      lines.each do |l|
        return l[/\A\s*/].length + 2 if l =~ /\A\s*tasks:\s*(#.*)?\z/
      end
      2
    end

    # Board with no `tasks:` key at all, or an empty one.
    def insert_first_task(lines, block)
      at = lines.index { |l| l =~ /\A\s*tasks:\s*(#.*)?\z/ }
      if at
        # Drop an inline `[]` if the key was written as `tasks: []`
        lines[at] = lines[at].sub(/:\s*\[\s*\]\s*\z/, ":")
        lines.insert(at + 1, *block)
      else
        lines << "" unless lines.empty? || lines.last.strip.empty?
        lines << "tasks:"
        lines.concat(block)
      end
    end

    # ---------- emitting YAML ----------

    def render_task(attrs, indent)
      a = attrs.transform_keys(&:to_s)
      pad = " " * indent
      inner = " " * (indent + 2)
      out = []

      ordered = KEY_ORDER.select { |k| meaningful?(a[k]) }
      extras  = a.keys - KEY_ORDER - ["checklist"]
      ordered += extras.select { |k| meaningful?(a[k]) }

      ordered.each_with_index do |key, i|
        prefix = i.zero? ? "#{pad}- " : inner
        out << "#{prefix}#{key}: #{scalar(a[key], key)}"
      end

      list = a["checklist"]
      if list.is_a?(Array) && !list.empty?
        prefix = out.empty? ? "#{pad}- " : inner
        out << "#{prefix}checklist:"
        list.each do |item|
          h = item.is_a?(Hash) ? item.transform_keys(&:to_s) : { "title" => item.to_s }
          title = h["title"].to_s
          next if title.strip.empty?

          out << "#{inner}  - #{scalar(h['done'] ? "x #{title}" : title, 'checklist')}"
        end
      end

      out << "#{pad}- {}" if out.empty?
      out
    end

    def meaningful?(value)
      return false if value.nil?
      return false if value.is_a?(String) && value.strip.empty?
      return false if value.is_a?(Array) && value.empty?

      true
    end

    def scalar(value, key = nil)
      case value
      when true, false then value.to_s
      when Integer     then value.to_s
      when Float       then (value == value.to_i ? value.to_i : value.round(4)).to_s
      when Numeric     then value.to_s
      else
        s = value.to_s
        # Times and durations always get quoted: "09:00" unquoted is a
        # sexagesimal integer in YAML 1.1, and 8 would become 8.0 silently.
        return dq(s) if %w[start end due].include?(key)

        needs_quotes?(s) ? dq(s) : s
      end
    end

    def needs_quotes?(str)
      return true if str.empty?
      return true if str != str.strip
      return true if str.match?(/\A[>|@`%*&!\[\]{}#,'"?-]/)
      return true if str.match?(/:\s|\s#/)
      return true if str.match?(/\A(true|false|yes|no|on|off|null|~)\z/i)
      return true if str.match?(/\A[\d.+-]/) # anything that could parse as a number/date
      return true if str.include?("\n")

      str.end_with?(":")
    end

    def dq(str)
      escaped = str.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", '\\n').gsub("\t", '\\t')
      "\"#{escaped}\""
    end
  end
end
