# frozen_string_literal: true

require "optparse"
require "rbconfig"
require "time"
require "json"

require_relative "board"
require_relative "app"
require_relative "http"
require_relative "server"
require_relative "importer"
require_relative "proposals"
require_relative "ai"

module MissionControlDashboard
  # Plain OptionParser CLI. Thor was a dependency the previous build did not
  # earn: this is five subcommands with a handful of flags.
  class CLI
    BANNER = <<~TXT
      Mission Control Dashboard v#{VERSION}

      Usage: mission_control <command> [options]

      Commands:
        server     Start the dashboard web server (default)
        open       Start the server and open a browser at it
        init       Write a starter board.yml (won't clobber an existing one)
        status     Print live tasks, next up and the goal countdown to the terminal
        archive    Snapshot a week into history/ with absolute dates (--week -1 for last week)
        history    List the archived weeks
        profile    Write a starter profile.yml (who the board is for; local only)
        import     Read a shared AI chat (markdown) into the review queue
        proposals  List, accept or discard what is waiting in the review queue
        path       Print the board file path
        doctor     Check the environment and validate the board
        version    Print the gem version

      Options:
        -p, --port PORT      Port to bind (default 4567)
        -H, --host HOST      Interface to bind (default 127.0.0.1)
        -b, --board PATH     Board file (default ~/.mission_control/board.yml,
                             override with MISSION_CONTROL_BOARD)
            --engine NAME    builtin (default) or sinatra
            --read-only      Serve the dashboard but refuse all edits
            --week N         archive: which week to snapshot (0 = this week, -1 = last)
            --ai             import: read the chat with Claude instead of the offline
                             parser (needs `gem install anthropic` + ANTHROPIC_API_KEY;
                             this is the only feature that uses the network)
            --accept ID      proposals: accept one (ALL to accept every proposal)
            --discard ID     proposals: discard one (ALL to empty the queue)
            --force          init/profile: overwrite an existing file; archive: re-archive a week
        -q, --quiet          Suppress request logging
        -h, --help           This message

      Examples:
        mission_control server -p 8080
        mission_control open
        mission_control status
        mission_control import ~/Downloads/claude-chat.md
        mission_control proposals --accept ALL
        MISSION_CONTROL_BOARD=./week.yml mission_control server
    TXT

    C = {
      reset: "\e[0m", dim: "\e[2m", bold: "\e[1m", green: "\e[32m", blue: "\e[36m",
      amber: "\e[33m", red: "\e[31m", grey: "\e[90m"
    }.freeze

    def run(argv)
      $stdout.sync = true # keep the banner and request log unbuffered (matters on Windows)
      opts = {
        port: 4567, host: "127.0.0.1", board: nil, engine: "builtin",
        force: false, quiet: false, open: false, read_only: false, week: 0,
        ai: false, accept: nil, discard: nil
      }

      parser = OptionParser.new do |o|
        o.banner = BANNER
        o.on("-p", "--port PORT", Integer) { |v| opts[:port] = v }
        o.on("-H", "--host HOST")          { |v| opts[:host] = v }
        o.on("-b", "--board PATH")         { |v| opts[:board] = v }
        o.on("--engine NAME")              { |v| opts[:engine] = v.downcase }
        o.on("--week N", Integer)          { |v| opts[:week] = v }
        o.on("--ai")                       { opts[:ai] = true }
        o.on("--accept ID")                { |v| opts[:accept] = v }
        o.on("--discard ID")               { |v| opts[:discard] = v }
        o.on("--force")                    { opts[:force] = true }
        o.on("--read-only")                { opts[:read_only] = true }
        o.on("-q", "--quiet")              { opts[:quiet] = true }
        o.on("--open")                     { opts[:open] = true }
        o.on("-h", "--help")               { puts BANNER; exit 0 }
        o.on("-v", "--version")            { puts VERSION; exit 0 }
      end

      args = argv.dup
      command = args.first && !args.first.start_with?("-") ? args.shift : "server"

      begin
        parser.parse!(args)
      rescue OptionParser::ParseError => e
        warn "#{C[:red]}#{e.message}#{C[:reset]}\n\n#{BANNER}"
        return 1
      end

      case command
      when "server"          then cmd_server(opts)
      when "open"            then cmd_server(opts.merge(open: true))
      when "init"            then cmd_init(opts)
      when "status", "tasks" then cmd_status(opts)
      when "archive"         then cmd_archive(opts)
      when "history"         then cmd_history(opts)
      when "profile"         then cmd_profile(opts)
      when "import"          then cmd_import(opts, args)
      when "proposals"       then cmd_proposals(opts)
      when "path"            then puts board_path(opts); 0
      when "doctor"          then cmd_doctor(opts)
      when "version"         then puts "Mission Control Dashboard v#{VERSION}"; 0
      when "help"            then puts BANNER; 0
      else
        warn "#{C[:red]}Unknown command: #{command}#{C[:reset]}\n\n#{BANNER}"
        1
      end
    end

    private

    def board_path(opts)
      opts[:board] ? File.expand_path(opts[:board]) : Board.default_path
    end

    def cmd_server(opts)
      path = board_path(opts)
      Board.install_seed(path)
      board = Board.new(path)

      # Fail fast with a readable message instead of a stack trace at request time.
      begin
        board.snapshot
      rescue Board::BoardError => e
        warn "#{C[:amber]}Board warning: #{e.message}#{C[:reset]}"
        warn "#{C[:grey]}Starting anyway - the browser will show the same error until you fix it.#{C[:reset]}"
      end

      app = App.new(board, writer: Writer.new(path), read_only: opts[:read_only])
      url = "http://#{opts[:host] == '0.0.0.0' ? '127.0.0.1' : opts[:host]}:#{opts[:port]}"

      if opts[:engine] == "sinatra"
        unless Server.available?
          warn "#{C[:red]}sinatra is not installed. Run `gem install sinatra` or drop --engine sinatra.#{C[:reset]}"
          return 1
        end
        banner(url, path, "sinatra", read_only: opts[:read_only])
        launch_browser(url) if opts[:open]
        Server.run!(app, host: opts[:host], port: opts[:port])
        return 0
      end

      server = HTTPServer.new(app, host: opts[:host], port: opts[:port], quiet: opts[:quiet])
      app.server = server
      banner(url, path, "builtin", read_only: opts[:read_only])
      launch_browser(url) if opts[:open]
      begin
        server.start
      rescue Errno::EADDRINUSE => e
        warn "#{C[:red]}#{e.message}#{C[:reset]}"
        return 1
      end
      puts "\n#{C[:grey]}Mission Control stopped.#{C[:reset]}"
      0
    end

    def banner(url, path, engine, read_only: false)
      mode = read_only ? "#{C[:amber]}read-only#{C[:reset]}" : "#{C[:dim]}editable#{C[:reset]}"
      hint = read_only ? "Editing is disabled. Restart without --read-only to change tasks." : "Add and edit tasks in the browser, or edit the file directly. Both write the same YAML."
      puts <<~OUT

        #{C[:green]}#{C[:bold]}  MISSION CONTROL ONLINE#{C[:reset]}
        #{C[:grey]}  ----------------------#{C[:reset]}
          Dashboard  #{C[:blue]}#{url}#{C[:reset]}
          Board      #{C[:dim]}#{path}#{C[:reset]} (#{mode})
          Engine     #{C[:dim]}#{engine} / ruby #{RUBY_VERSION}#{C[:reset]}

        #{C[:grey]}  #{hint}
          Ctrl-C to stop.#{C[:reset]}

      OUT
    end

    def cmd_init(opts)
      path = board_path(opts)
      if Board.install_seed(path, force: opts[:force])
        puts "#{C[:green]}Wrote starter board:#{C[:reset]} #{path}"
      else
        puts "#{C[:amber]}Board already exists:#{C[:reset]} #{path}"
        puts "#{C[:grey]}Pass --force to overwrite it.#{C[:reset]}"
      end
      0
    end

    def cmd_archive(opts)
      arch = Archive.new(Board.new(board_path(opts)))
      saved = arch.write(week_offset: opts[:week], force: opts[:force])
      label = opts[:week].zero? ? "this week" : "#{opts[:week].abs} week#{opts[:week] == -1 ? '' : 's'} back"
      puts "#{C[:green]}Archived #{label} as #{saved['week']}:#{C[:reset]} #{saved['path']}"
      0
    rescue Archive::ExistsError => e
      warn "#{C[:amber]}#{e.message}#{C[:reset]}"
      warn "#{C[:grey]}Pass --force to overwrite it with the current view.#{C[:reset]}"
      1
    rescue Archive::ArchiveError, Board::BoardError => e
      warn "#{C[:red]}#{e.message}#{C[:reset]}"
      1
    end

    def cmd_history(opts)
      arch = Archive.new(Board.new(board_path(opts)))
      weeks = arch.list
      if weeks.empty?
        puts "#{C[:grey]}No archived weeks yet. Run `mission_control archive` at the end of a week " \
             "(or `archive --week -1` on Monday).#{C[:reset]}"
        return 0
      end

      puts "\n#{C[:bold]}Archived weeks#{C[:reset]} #{C[:grey]}(#{arch.dir})#{C[:reset]}\n\n"
      weeks.each do |w|
        goal = w["goal"].empty? ? "" : " #{C[:grey]}- #{w['goal']}#{C[:reset]}"
        puts "  #{C[:blue]}#{w['week']}#{C[:reset]}  #{w['week_start'][0, 10]} " \
             "#{C[:grey]}->#{C[:reset]} #{w['week_end'][0, 10]}  " \
             "#{w['done']}/#{w['tasks']} done#{goal}"
      end
      puts
      0
    end

    def cmd_profile(opts)
      profile = Profile.new(Profile.default_path(board_path(opts)))
      if profile.install_seed(force: opts[:force])
        puts "#{C[:green]}Wrote starter profile:#{C[:reset]} #{profile.path}"
        puts "#{C[:grey]}Every field ships commented out - uncomment what is true about you. " \
             "It stays on this machine.#{C[:reset]}"
      else
        puts "#{C[:amber]}Profile already exists:#{C[:reset]} #{profile.path}"
        puts "#{C[:grey]}Pass --force to overwrite it with the template.#{C[:reset]}"
      end
      0
    end

    def cmd_import(opts, args)
      file = args.find { |a| !a.start_with?("-") }
      unless file
        warn "#{C[:red]}Which file? e.g. mission_control import ./chat.md#{C[:reset]}"
        warn "#{C[:grey]}Export or paste a chat as markdown first. Add --ai to read it " \
             "with Claude instead of the offline parser.#{C[:reset]}"
        return 1
      end
      unless File.exist?(file)
        warn "#{C[:red]}No such file: #{file}#{C[:reset]}"
        return 1
      end

      text = File.read(file, encoding: "UTF-8")
      source = File.basename(file)
      board = Board.new(board_path(opts))
      queue = Proposals.new(Proposals.default_path(board.path))

      candidates, warnings = read_chat(text, source, board, opts)
      return 1 if candidates.nil?

      added = queue.add(candidates, origin: opts[:ai] ? "ai" : "import")
      warnings.each { |w| puts "  #{C[:amber]}!#{C[:reset]} #{w}" }

      if added.empty?
        puts "#{C[:amber]}Nothing new.#{C[:reset]} #{C[:grey]}#{candidates.length} candidate(s) " \
             "read, all already in the queue.#{C[:reset]}"
        return 0
      end

      puts "\n#{C[:green]}#{added.length} proposal#{added.length == 1 ? '' : 's'} " \
           "queued#{C[:reset]} #{C[:grey]}from #{source}#{C[:reset]}\n\n"
      added.each { |p| print_proposal(p) }
      puts "\n#{C[:grey]}Nothing is on your board yet. Review them in the dashboard, or:" \
           "\n  mission_control proposals --accept ALL#{C[:reset]}\n\n"
      0
    rescue Proposals::ProposalError => e
      warn "#{C[:red]}#{e.message}#{C[:reset]}"
      1
    end

    # Returns [candidates, warnings] or [nil, _] when the AI path is asked
    # for and cannot run — falling back silently would hide a paid feature
    # quietly not happening.
    def read_chat(text, source, board, opts)
      unless opts[:ai]
        importer = Importer.new
        return [importer.parse(text, source: source), importer.warnings]
      end

      if (reason = AI.unavailable_reason)
        warn "#{C[:red]}Cannot use --ai: #{reason}#{C[:reset]}"
        return [nil, []]
      end

      tracks = begin
        board.snapshot["tracks"]
      rescue StandardError
        []
      end
      puts "#{C[:grey]}Reading #{source} with #{AI::MODEL}...#{C[:reset]}"
      [AI.propose(text, tracks: tracks, source: source), []]
    rescue AI::AIError => e
      warn "#{C[:red]}#{e.message}#{C[:reset]}"
      [nil, []]
    end

    def print_proposal(p)
      bits = []
      bits << p["start"] if p["start"]
      bits << "#{p['effort']}h" if p["effort"]
      bits << p["status"] if p["status"] && p["status"] != "todo"
      meta = bits.empty? ? "" : " #{C[:grey]}[#{bits.join(' · ')}]#{C[:reset]}"
      puts "  #{C[:blue]}#{p['id']}#{C[:reset]}  #{p['title']}#{meta}"
      puts "        #{C[:grey]}#{p['track']} · from #{p['source']}#{C[:reset]}"
    end

    def cmd_proposals(opts)
      board = Board.new(board_path(opts))
      queue = Proposals.new(Proposals.default_path(board.path))

      return accept_proposals(board, queue, opts[:accept]) if opts[:accept]
      return discard_proposals(queue, opts[:discard]) if opts[:discard]

      list = queue.list
      if list.empty?
        puts "#{C[:grey]}The review queue is empty. Import a chat with " \
             "`mission_control import ./chat.md`.#{C[:reset]}"
        return 0
      end

      puts "\n#{C[:bold]}Review queue#{C[:reset]} #{C[:grey]}(#{list.length} waiting · " \
           "#{queue.path})#{C[:reset]}\n\n"
      list.each { |p| print_proposal(p) }
      puts "\n#{C[:grey]}Nothing here is on your board. " \
           "--accept ID / --discard ID, or ALL for every one.#{C[:reset]}\n\n"
      0
    end

    def accept_proposals(board, queue, which)
      app = App.new(board, writer: Writer.new(board.path), proposals: queue)
      targets = which.to_s.upcase == "ALL" ? queue.list.map { |p| p["id"] } : [which]
      return empty_queue_note if targets.empty?

      ok = 0
      targets.each do |id|
        status, _type, body = app.call("POST", "/api/proposals/#{id}/accept", {}, "{}",
                                       "host" => "127.0.0.1", "x-mission-control" => "1")
        doc = JSON.parse(body)
        if status == 201
          ok += 1
          puts "  #{C[:green]}added#{C[:reset]} #{doc['id']}"
        else
          warn "  #{C[:red]}#{doc['error']}#{C[:reset]}"
        end
      end
      puts "\n#{C[:green]}#{ok} added to#{C[:reset]} #{board.path}" \
           " #{C[:grey]}(#{queue.count} still queued)#{C[:reset]}\n\n"
      ok.positive? ? 0 : 1
    end

    def discard_proposals(queue, which)
      if which.to_s.upcase == "ALL"
        n = queue.clear
        puts "#{C[:green]}Discarded #{n} proposal#{n == 1 ? '' : 's'}.#{C[:reset]}"
        return 0
      end

      gone = queue.remove(which)
      puts "#{C[:green]}Discarded#{C[:reset]} #{gone['title']}"
      0
    rescue Proposals::ProposalError => e
      warn "#{C[:red]}#{e.message}#{C[:reset]}"
      1
    end

    def empty_queue_note
      puts "#{C[:grey]}The review queue is empty.#{C[:reset]}"
      0
    end

    def cmd_status(opts)
      snap = Board.new(board_path(opts)).snapshot
      g = snap["goal"]
      st = snap["stats"]

      puts "\n#{C[:bold]}#{snap['meta']['title']}#{C[:reset]} #{C[:grey]}- #{Time.now.strftime('%a %d %b %H:%M')}#{C[:reset]}"

      if g["set"]
        left = g["seconds_left"]
        tone = g["at_risk"] || g["passed"] ? C[:red] : C[:green]
        puts "\n#{C[:blue]}GOAL#{C[:reset]}  #{g['label']}"
        puts "      #{tone}#{humanize(left)}#{C[:reset]} #{C[:grey]}(#{Time.parse(g['due']).strftime('%a %d %b %H:%M')})#{C[:reset]}"
        puts "      #{format('%.1f', g['work_left'])}h of work left vs #{format('%.1f', g['capacity'])}h of working time " \
             "#{g['at_risk'] ? "#{C[:red]}OVER by #{format('%.1f', -g['slack'])}h#{C[:reset]}" : "#{C[:green]}#{format('%.1f', g['slack'])}h slack#{C[:reset]}"}"
      end

      section("LIVE NOW", snap["tasks"].select { |t| t["state"] == "live" }, C[:blue])
      section("BLOCKED",  snap["tasks"].select { |t| t["state"] == "blocked" }, C[:amber])
      section("OVERDUE",  snap["tasks"].select { |t| t["state"] == "overdue" }, C[:red])
      section("UP NEXT",  snap["tasks"].select { |t| t["state"] == "upcoming" }
                              .sort_by { |t| t["start_ms"] }.first(4), C[:grey])

      puts "\n#{C[:grey]}#{st['done']}/#{st['total']} done - #{st['hours_booked']}h booked this week#{C[:reset]}"
      snap["warnings"].each { |w| puts "#{C[:amber]}! #{w}#{C[:reset]}" }
      puts
      0
    rescue Board::BoardError => e
      warn "#{C[:red]}#{e.message}#{C[:reset]}"
      1
    end

    def section(label, tasks, colour)
      return if tasks.empty?

      puts "\n#{colour}#{label}#{C[:reset]}"
      tasks.each do |t|
        s = Time.parse(t["start"])
        e = Time.parse(t["end"])
        pct = t["progress"].positive? ? " #{(t['progress'] * 100).round}%" : ""
        puts "  #{colour}#{s.strftime('%a %H:%M')}-#{e.strftime('%H:%M')}#{C[:reset]}  " \
             "#{t['title']} #{C[:grey]}[#{t['track']}]#{pct}#{C[:reset]}"
        puts "      #{C[:amber]}#{t['notes']}#{C[:reset]}" unless t["notes"].empty?
      end
    end

    def humanize(sec)
      past = sec.negative?
      sec = sec.abs
      d = sec / 86_400
      h = (sec % 86_400) / 3600
      m = (sec % 3600) / 60
      out = d.positive? ? "#{d}d #{h}h #{m}m" : "#{h}h #{m}m"
      past ? "#{out} overdue" : "#{out} remaining"
    end

    def cmd_doctor(opts)
      path = board_path(opts)
      puts "\n#{C[:bold]}Mission Control doctor#{C[:reset]}\n\n"
      line "ruby #{RUBY_VERSION} (#{RbConfig::CONFIG['host_os']})", true
      line "gem version #{VERSION}", true
      line "board path #{path}", true
      line "board exists", File.exist?(path)
      optional "sinatra installed (optional engine)", Server.available?

      begin
        snap = Board.new(path).snapshot
        line "board parses", true
        line "#{snap['tasks'].length} tasks across #{snap['tracks'].length} tracks", true
        optional "goal configured (enables countdown + capacity)", snap["goal"]["set"]
        optional "profile configured (personalises warnings)",
                 Profile.new(Profile.default_path(path)).summary["set"]
        archived = Archive.new(Board.new(path)).list.length
        optional "history archived (#{archived} week#{archived == 1 ? '' : 's'})", archived.positive?
        queued = Proposals.new(Proposals.default_path(path)).count
        optional "review queue (#{queued} waiting)", queued.positive?
        optional "anthropic gem (optional, only for `import --ai`)", AI.available?
        optional "ANTHROPIC_API_KEY set (only for `import --ai`)", AI.key?
        snap["warnings"].each { |w| puts "  #{C[:amber]}!#{C[:reset]} #{w}" }
      rescue Board::BoardError => e
        line "board parses", false
        puts "  #{C[:red]}#{e.message}#{C[:reset]}"
        puts
        return 1
      end
      puts
      0
    end

    def line(label, ok)
      puts "  #{ok ? "#{C[:green]}ok  #{C[:reset]}" : "#{C[:red]}FAIL#{C[:reset]}"} #{label}"
    end

    # For things whose absence is fine - never print a scary FAIL for them.
    def optional(label, present)
      puts "  #{present ? "#{C[:green]}ok  #{C[:reset]}" : "#{C[:grey]}--  #{C[:reset]}"} #{label}"
    end

    def launch_browser(url)
      cmd = case RbConfig::CONFIG["host_os"]
            when /mswin|mingw|cygwin/ then ["cmd", "/c", "start", "", url]
            when /darwin/             then ["open", url]
            else                           ["xdg-open", url]
            end
      Thread.new do
        sleep 0.6
        begin
          system(*cmd, out: File::NULL, err: File::NULL)
        rescue StandardError
          nil
        end
      end
    end
  end
end
