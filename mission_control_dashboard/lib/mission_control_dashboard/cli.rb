# frozen_string_literal: true

require "optparse"
require "rbconfig"
require "time"

require_relative "board"
require_relative "app"
require_relative "http"
require_relative "server"

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
            --force          init/profile: overwrite an existing file; archive: re-archive a week
        -q, --quiet          Suppress request logging
        -h, --help           This message

      Examples:
        mission_control server -p 8080
        mission_control open
        mission_control status
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
        force: false, quiet: false, open: false, read_only: false, week: 0
      }

      parser = OptionParser.new do |o|
        o.banner = BANNER
        o.on("-p", "--port PORT", Integer) { |v| opts[:port] = v }
        o.on("-H", "--host HOST")          { |v| opts[:host] = v }
        o.on("-b", "--board PATH")         { |v| opts[:board] = v }
        o.on("--engine NAME")              { |v| opts[:engine] = v.downcase }
        o.on("--week N", Integer)          { |v| opts[:week] = v }
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
