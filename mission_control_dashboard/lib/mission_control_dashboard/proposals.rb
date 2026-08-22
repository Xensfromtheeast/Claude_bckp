# frozen_string_literal: true

require "yaml"
require "date"
require "digest"
require "fileutils"

module MissionControlDashboard
  # The review queue: `proposals.yml` beside the board.
  #
  # Nothing that comes out of a chat log — or out of a language model — is
  # allowed to write to board.yml. It lands here first, and a person accepts
  # it, edits it, or throws it away. That is the whole safety story of chat
  # import: the parser and the model *propose*, the operator *disposes*, and
  # an accepted proposal still goes through the same validation and key
  # allow-list as anything typed into the editor by hand.
  #
  # Proposals are disposable, so this is a plain rewritten file rather than
  # the comment-preserving surgical path board.yml gets. Losing a comment
  # you wrote inside a queue of suggestions costs nothing; losing one in
  # your board would.
  class Proposals
    class ProposalError < StandardError; end

    ID_RE = /\A[a-z0-9]{8,32}\z/.freeze
    MAX_OPEN = 200

    # Fields a proposal may carry. Everything else a parser or a model
    # invents is dropped here, before it ever reaches the writer.
    FIELDS = %w[title track start end duration effort status progress owner
                notes checklist].freeze
    META = %w[id source line evidence origin created].freeze

    attr_reader :path

    def self.default_path(board_path)
      File.join(File.dirname(File.expand_path(board_path)), "proposals.yml")
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def exist?
      File.exist?(@path)
    end

    # Newest first — the batch you just imported is the one you want to see.
    def list
      load_all.sort_by { |p| p["created"].to_s }.reverse
    end

    def find(id)
      load_all.find { |p| p["id"] == id.to_s }
    end

    def count
      load_all.length
    end

    # Adds candidates, skipping ones already queued (same title + source).
    # Returns the proposals actually added.
    def add(candidates, origin: "import")
      existing = load_all
      seen = existing.each_with_object({}) { |p, acc| acc[dedup_key(p)] = true }
      now = Time.now

      fresh = Array(candidates).filter_map do |raw|
        p = sanitize(raw, origin: origin, at: now)
        next if p.nil?

        key = dedup_key(p)
        next if seen[key]

        seen[key] = true
        p
      end

      return [] if fresh.empty?

      combined = existing + fresh
      if combined.length > MAX_OPEN
        raise ProposalError,
              "the review queue is full (#{MAX_OPEN}). Accept or discard what is " \
              "already there before importing more."
      end

      save(combined)
      fresh
    end

    def remove(id)
      all = load_all
      hit = all.find { |p| p["id"] == id.to_s }
      raise ProposalError, "no proposal #{id.inspect}" unless hit

      save(all - [hit])
      hit
    end

    def clear
      n = load_all.length
      save([])
      n
    end

    # The task attributes an accepted proposal contributes, with the review
    # metadata stripped. The caller hands these to the normal write path so
    # they get the same validation as a hand-typed task.
    def to_task(proposal, overrides = {})
      attrs = proposal.reject { |k, _| META.include?(k) }
      overrides.each { |k, v| attrs[k.to_s] = v if FIELDS.include?(k.to_s) }
      attrs.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
    end

    private

    def dedup_key(p)
      "#{p['title'].to_s.downcase.strip}|#{p['source']}"
    end

    def sanitize(raw, origin:, at:)
      return nil unless raw.is_a?(Hash)

      h = raw.transform_keys(&:to_s)
      title = h["title"].to_s.strip
      return nil if title.empty?

      out = { "title" => title[0, 200] }
      (FIELDS - ["title"]).each do |k|
        v = h[k]
        next if v.nil?

        out[k] = case k
                 when "checklist" then checklist(v)
                 when "effort", "duration", "progress" then numeric(v)
                 else v.to_s.strip[0, 500]
                 end
      end
      out.reject! { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }

      out["source"]   = h["source"].to_s[0, 200]
      out["line"]     = h["line"].to_i if h["line"]
      out["evidence"] = h["evidence"].to_s[0, 300] unless h["evidence"].to_s.empty?
      out["origin"]   = origin.to_s
      out["created"]  = at.strftime("%Y-%m-%dT%H:%M:%S%:z")
      out["id"]       = id_for(out)
      out
    end

    def checklist(value)
      return nil unless value.is_a?(Array)

      value.filter_map do |item|
        h = item.is_a?(Hash) ? item.transform_keys(&:to_s) : { "title" => item.to_s }
        t = h["title"].to_s.strip
        next if t.empty?

        { "title" => t[0, 200], "done" => [true, "true", 1, "1"].include?(h["done"]) }
      end
    end

    def numeric(value)
      f = Float(value.to_s)
      f.positive? ? f : nil
    rescue ArgumentError, TypeError
      nil
    end

    def id_for(p)
      Digest::SHA256.hexdigest("#{p['title']}|#{p['source']}|#{p['line']}|#{p['created']}")[0, 12]
    end

    def load_all
      return [] unless exist?

      doc = YAML.safe_load(File.read(@path, encoding: "UTF-8"),
                           permitted_classes: [Date, Time, DateTime], aliases: true)
      rows = doc.is_a?(Hash) ? doc["proposals"] : doc
      return [] unless rows.is_a?(Array)

      rows.filter_map do |r|
        next unless r.is_a?(Hash)

        h = r.transform_keys(&:to_s)
        next if h["title"].to_s.strip.empty?
        next unless h["id"].to_s.match?(ID_RE)

        h
      end
    rescue Psych::SyntaxError
      # A queue of suggestions is never worth taking the dashboard down for.
      []
    end

    def save(rows)
      FileUtils.mkdir_p(File.dirname(@path))
      body = HEADER + YAML.dump("proposals" => rows)
      tmp = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp, body, encoding: "UTF-8")
      File.rename(tmp, @path)
    ensure
      begin
        File.unlink(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        nil
      end
    end

    HEADER = <<~TXT
      # Review queue — candidate tasks from imported chats.
      #
      # NOTHING HERE IS ON YOUR BOARD. These are suggestions waiting for you
      # to accept or discard, in the dashboard or with `mission_control
      # proposals`. Editing this file by hand is fine; it is rewritten
      # wholesale on every accept/discard, so comments here do not survive.
    TXT
  end
end
