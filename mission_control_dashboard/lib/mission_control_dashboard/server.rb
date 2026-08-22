# frozen_string_literal: true

module MissionControlDashboard
  # Optional Sinatra backend, kept only for people who want to bolt
  # middleware onto the dashboard later. Nothing in the gem requires it:
  # `mission_control server` uses the built-in stdlib server by default.
  # Opt in with `mission_control server --engine sinatra`.
  module Server
    module_function

    def available?
      require "sinatra/base"
      true
    rescue LoadError
      false
    end

    def run!(app, host:, port:)
      require "sinatra/base"

      klass = Class.new(Sinatra::Base) do
        set :logging, true
        set :show_exceptions, false

        App::ROUTES.each do |route|
          get route do
            code, type, payload = app.call("GET", request.path_info, params)
            status code
            content_type type
            payload
          end
        end

        not_found do
          content_type "text/plain"
          "Not found. Try / or /api/board\n"
        end
      end

      klass.set :bind, host
      klass.set :port, port
      klass.run!
    end
  end
end
