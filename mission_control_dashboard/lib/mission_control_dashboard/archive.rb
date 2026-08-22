# frozen_string_literal: true

require "yaml"
require "date"
require "fileutils"

require_relative "board"

module MissionControlDashboard
  # Week history, as write-once snapshots.
  #
  # The live board cannot show real history: a weekday-relative task
  # ("mon 09:00") is re-resolved against whichever week you page to, so the
  # <- button shows a *replay* of the current file, not what last week
  # actually contained. An archive fixes that by capturing the fully
  # resolved snapshot — absolute timestamps, statuses, progress, the goal
  # and the capacity numbers as they stood — into one YAML file per week
  # under history/ next to the board.
  #
  # Archives are snapshots, not documents you hand-edit, so they go through
  # a plain atomic write rather than the comment-preserving surgical path.
  class Archive
    class ArchiveError < StandardError; end
    class ExistsError < ArchiveError; end

    # "2026-W34" — ISO week of the snapshot's Monday. Also the filename, so
    # it is validated hard: nothing that isn't a week id touches the disk.
    ID_RE = /\A\d{4}-W\d{2}\z/.freeze

    attr_reader :dir

    def initialize(board)
      @board = board
      @dir = File.join(File.dirname(board.path), "history")
    end

    def id_for(week_start)
      d = Date.parse(week_start.to_s[0, 10])
      format("%04d-W%02d", d.cwyear, d.cweek)
    rescue ArgumentError, TypeError
      nil
    end

    def exist?(id)
      !!(id && id.match?(ID_RE) && File.exist?(path_for(id)))
    end

    # Snapshot the given week (0 = this week, -1 = last week) into
    # history/<id>.yml. Archiving the future is refused — there is nothing
    # true to capture yet. Returns { "week" =>, "path" => }.
    def write(now: Time.now, week_offset: 0, force: false)
      raise ArchiveError, "cannot archive a future week" if week_offset.positive?

      snap = @board.snapshot(now: now, week_offset: week_offset)
      id   = id_for(snap["meta"]["week_start"])
      raise ArchiveError, "could not derive a week id from the board" unless id

      path = path_for(id)
      if File.exist?(path) && !force
        raise ExistsError, "an archive for #{id} already exists at #{path}"
      end

      doc = {
        "week"        => id,
        "archived_at" => snap["meta"]["now"],
        # week_offset / now / generated are viewer state, not history.
        "meta"        => snap["meta"].reject { |k, _| %w[week_offset now generated].include?(k) },
        "goal"        => snap["goal"],
        "stats"       => snap["stats"],
        "tracks"      => snap["tracks"],
        "tasks"       => snap["tasks"]
      }

      FileUtils.mkdir_p(@dir)
      atomic_write(path, HEADER + YAML.dump(doc))
      { "week" => id, "path" => path }
    end

    # Newest first. Each entry is a one-line summary; read(id) gets the rest.
    def list
      return [] unless Dir.exist?(@dir)

      Dir.glob(File.join(@dir, "*.yml")).filter_map do |f|
        id = File.basename(f, ".yml")
        next unless id.match?(ID_RE)

        doc = load_file(f)
        next unless doc

        {
          "week"        => id,
          "week_start"  => doc.dig("meta", "week_start").to_s,
          "week_end"    => doc.dig("meta", "week_end").to_s,
          "archived_at" => doc["archived_at"].to_s,
          "tasks"       => Array(doc["tasks"]).length,
          "done"        => doc.dig("stats", "done").to_i,
          "goal"        => doc.dig("goal", "label").to_s
        }
      end.sort_by { |e| e["week"] }.reverse
    end

    def read(id)
      return nil unless id && id.match?(ID_RE)

      load_file(path_for(id))
    end

    private

    HEADER = <<~TXT
      # Archived week snapshot — written by `mission_control archive`.
      # Timestamps are absolute; this file is history, not a live board.
      # The dashboard serves it read-only via /api/history.
    TXT

    def path_for(id)
      raise ArchiveError, "bad archive id #{id.inspect}" unless id.match?(ID_RE)

      File.join(@dir, "#{id}.yml")
    end

    def load_file(path)
      return nil unless File.exist?(path)

      doc = YAML.safe_load(File.read(path, encoding: "UTF-8"),
                           permitted_classes: [Date, Time, DateTime], aliases: true)
      doc.is_a?(Hash) ? doc : nil
    rescue Psych::SyntaxError
      nil
    end

    def atomic_write(path, body)
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, body, encoding: "UTF-8")
      File.rename(tmp, path)
    ensure
      begin
        File.unlink(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        nil
      end
    end
  end
end
