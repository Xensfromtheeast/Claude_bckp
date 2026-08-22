# frozen_string_literal: true

require "json"

require_relative "board"
require_relative "view"
require_relative "writer"

module MissionControlDashboard
  # Server-agnostic routing. Takes (method, path, params, body, headers) and
  # returns [status, content_type, body]. Both the built-in server and the
  # optional Sinatra adapter are thin wrappers over this, so there is exactly
  # one place where the app's behaviour lives.
  class App
    ROUTES = %w[/ /api/board /api/tasks /healthz].freeze
    READS  = %w[GET HEAD].freeze
    WRITES = %w[POST PATCH PUT DELETE].freeze

    # Any host that is not loopback could be a DNS-rebinding attack pointing a
    # public name at 127.0.0.1. A read-only dashboard shrugs that off; one that
    # writes files does not.
    LOOPBACK = /\A(localhost|127(\.\d+){3}|\[?::1\]?|0\.0\.0\.0)(:\d+)?\z/i.freeze

    def initialize(board, writer: nil, read_only: false, server: nil)
      @board = board
      @writer = writer || Writer.new(board.path)
      @read_only = read_only
      @server = server
    end

    # Let the server hand itself over after construction, so /healthz can
    # report live connection counts and dropped log lines. If the dashboard
    # ever stalls again, `curl /healthz` from another terminal says whether
    # the process is wedged or merely idle.
    attr_writer :server

    def call(method, path, params = {}, body = "", headers = {})
      method = method.to_s.upcase

      if WRITES.include?(method)
        guard = write_guard(method, headers)
        return guard if guard
      elsif !READS.include?(method)
        return [405, "text/plain", "Method not allowed\n"]
      end

      case [method, path]
      in ["GET" | "HEAD", "/"]          then html(params)
      in ["GET" | "HEAD", "/api/board"] then api(params)
      in ["GET" | "HEAD", "/healthz"]   then [200, JSON_T, JSON.generate(health)]
      in ["GET" | "HEAD", "/favicon.ico"] then [204, "image/x-icon", ""]
      in ["POST", "/api/tasks"]         then create_task(body)
      in [("PATCH" | "PUT"), %r{\A/api/tasks/(?<id>.+)\z}]  then update_task(Regexp.last_match[:id], body)
      in ["DELETE", %r{\A/api/tasks/(?<id>.+)\z}]           then delete_task(Regexp.last_match[:id])
      else
        [404, "text/plain", "Not found. Try / or /api/board\n"]
      end
    end

    private

    JSON_T = "application/json; charset=utf-8"

    def health
      base = { "ok" => true, "version" => VERSION, "read_only" => @read_only,
               "pid" => Process.pid, "threads" => Thread.list.count }
      @server.respond_to?(:stats) ? base.merge(@server.stats) : base
    end

    # ---------- guards ----------

    def write_guard(_method, headers)
      if @read_only
        return json_error(403, "This dashboard is running read-only. Restart without --read-only to edit.")
      end

      host = headers["host"].to_s
      unless host.empty? || host.match?(LOOPBACK)
        return json_error(403, "Writes are only accepted over a loopback address (got Host: #{host}).")
      end

      # A cross-origin <form> POST cannot set a custom header without a CORS
      # preflight, and we never send CORS headers — so requiring this header
      # is enough to stop a random web page from editing your board.
      unless headers["x-mission-control"] == "1"
        return json_error(403, "Missing X-Mission-Control header; refusing a possible cross-site write.")
      end

      nil
    end

    # ---------- reads ----------

    def html(params)
      [200, "text/html; charset=utf-8", View.render(snapshot(params))]
    rescue Board::BoardError => e
      [500, "text/html; charset=utf-8", View.error_page(e.message)]
    end

    def api(params)
      [200, JSON_T, JSON.generate(snapshot(params))]
    rescue Board::BoardError => e
      [500, JSON_T, JSON.generate("error" => e.message)]
    end

    def snapshot(params)
      offset = params["week"].to_i
      offset = 0 if offset.abs > 260 # sanity clamp: +/- 5 years
      @board.snapshot(now: Time.now, week_offset: offset).merge("rev" => @writer.revision,
                                                                "read_only" => @read_only)
    end

    # ---------- writes ----------

    def create_task(body)
      payload = parse_json(body)
      return payload if payload.is_a?(Array)

      attrs = clean(payload["task"] || payload)
      attrs["id"] = next_id(attrs["title"]) if attrs["id"].to_s.strip.empty?
      err = validate(attrs)
      return json_error(422, err) if err

      saved = @writer.add_task(attrs, rev: payload["rev"])
      [201, JSON_T, JSON.generate(saved.merge("ok" => true))]
    rescue Writer::ConflictError => e
      json_error(409, e.message)
    rescue Writer::WriteError, Board::BoardError => e
      json_error(422, e.message)
    end

    def update_task(id, body)
      payload = parse_json(body)
      return payload if payload.is_a?(Array)

      attrs = clean(payload["task"] || payload, allow_nil: true)
      err = validate(attrs, partial: true)
      return json_error(422, err) if err

      saved = @writer.update_task(unescape(id), attrs, rev: payload["rev"])
      [200, JSON_T, JSON.generate(saved.merge("ok" => true))]
    rescue Writer::ConflictError => e
      json_error(409, e.message)
    rescue Writer::WriteError, Board::BoardError => e
      json_error(422, e.message)
    end

    def delete_task(id)
      saved = @writer.delete_task(unescape(id))
      [200, JSON_T, JSON.generate(saved.merge("ok" => true))]
    rescue Writer::ConflictError => e
      json_error(409, e.message)
    rescue Writer::WriteError => e
      json_error(422, e.message)
    end

    # ---------- helpers ----------

    def parse_json(body)
      doc = JSON.parse(body.to_s.empty? ? "{}" : body)
      return json_error(422, "Expected a JSON object.") unless doc.is_a?(Hash)

      doc
    rescue JSON::ParserError => e
      json_error(422, "Malformed JSON: #{e.message}")
    end

    # Only ever write keys we understand. Anything else the browser sends is
    # dropped rather than smuggled into the user's file.
    def clean(raw, allow_nil: false)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(k, v), acc|
        key = k.to_s
        next unless Writer::EDITABLE.include?(key)
        next if v.nil? && !allow_nil

        acc[key] = case key
                   when "progress", "effort", "duration" then v.nil? ? nil : v.to_f
                   when "checklist" then clean_checklist(v)
                   else v.is_a?(String) ? v.strip : v
                   end
      end
    end

    def clean_checklist(list)
      return [] unless list.is_a?(Array)

      list.filter_map do |item|
        h = item.is_a?(Hash) ? item : { "title" => item.to_s }
        title = (h["title"] || h[:title]).to_s.strip
        next if title.empty?

        { "title" => title, "done" => [true, "true", 1, "1"].include?(h["done"] || h[:done]) }
      end
    end

    def validate(attrs, partial: false)
      unless partial
        return "A task needs a title." if attrs["title"].to_s.strip.empty?
        return "A task needs a start time." if attrs["start"].to_s.strip.empty?
      end

      if attrs.key?("status") && !Board::STATUSES.include?(attrs["status"].to_s)
        return "Unknown status #{attrs['status'].inspect}. Use: #{Board::STATUSES.join(', ')}."
      end

      %w[effort duration].each do |k|
        return "#{k} must be a positive number of hours." if attrs[k] && attrs[k].to_f <= 0
      end

      if attrs["progress"] && !(0.0..1.0).cover?(attrs["progress"].to_f)
        return "progress must be between 0 and 1."
      end

      # Reject times the board itself cannot read, so a typo surfaces in the
      # editor rather than as a silently-skipped task after saving.
      %w[start end].each do |k|
        next if attrs[k].to_s.strip.empty?
        next if @board.readable_time?(attrs[k])

        return "Could not read #{k} #{attrs[k].inspect}. Try \"mon 09:00\" or \"2026-08-14 17:00\"."
      end

      nil
    end

    def next_id(title)
      base = title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      base = "task" if base.empty?
      base = base[0, 32]
      existing = begin
        @board.snapshot["tasks"].map { |t| t["id"] }
      rescue StandardError
        []
      end
      return base unless existing.include?(base)

      n = 2
      n += 1 while existing.include?("#{base}-#{n}")
      "#{base}-#{n}"
    end

    def unescape(str)
      URI.decode_www_form_component(str.to_s)
    rescue ArgumentError
      str.to_s
    end

    def json_error(code, message)
      [code, JSON_T, JSON.generate("ok" => false, "error" => message)]
    end
  end
end
