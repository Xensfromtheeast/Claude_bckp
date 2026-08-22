# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mission_control_dashboard/version"

Gem::Specification.new do |spec|
  spec.name        = "mission_control_dashboard"
  spec.version     = MissionControlDashboard::VERSION
  spec.authors     = ["Xens"]
  spec.email       = ["samdamic34@gmail.com"]

  spec.summary     = "Week timeline, Gantt and goal-capacity dashboard as a zero-dependency Ruby gem"
  spec.description = "A local mission control dashboard: an hour-resolution week Gantt chart, " \
                     "live task telemetry, a pending-goal countdown with a capacity check, " \
                     "week archiving and chat import, driven by a plain YAML file. Runs on " \
                     "Ruby's standard library alone - no Rails, no Sinatra, no Rack, no build step."
  spec.homepage    = "https://github.com/xens/mission_control_dashboard"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage

  # Dir.glob, not `git ls-files` - so building from an unzipped folder works.
  spec.files = Dir.glob("lib/**/*.rb") +
               Dir.glob("bin/*") +
               ["README.md", "Rakefile", "mission_control_dashboard.gemspec"].select { |f| File.exist?(f) }

  spec.bindir             = "bin"
  spec.executables        = ["mission_control"]
  spec.require_paths      = ["lib"]

  # No runtime dependencies. That is the point.
  #
  # Two features are supported but optional, and neither is needed for the
  # dashboard itself:
  #   sinatra   `gem install sinatra` -> `mission_control server --engine sinatra`
  #   anthropic `gem install anthropic` -> `mission_control import chat.md --ai`
  # Both are required lazily; without them everything else works unchanged,
  # and chat import falls back to the offline parser.
  spec.add_development_dependency "rake", "~> 13.0"
end
