# frozen_string_literal: true

module MissionControlDashboard
  # The board file written on first run. Times use weekday-relative syntax
  # ("mon 09:00") so the board never goes stale week to week. Absolute
  # timestamps ("2026-08-14 17:00") work too and pin to a real date.
  SEED_BOARD = <<~YAML
    # ~/.mission_control/board.yml
    # Edit this file, refresh the browser. That is the whole workflow.
    #
    # TIME SYNTAX
    #   "mon 09:00"            -> Monday of the week you are viewing
    #   "today 14:00"          -> today
    #   "tomorrow 09:30"       -> tomorrow
    #   "2026-08-14 17:00"     -> pinned to a real calendar date
    #
    # A task needs a start plus EITHER an end OR a duration (in hours).

    meta:
      title: Mission Control
      operator: Xens
      # Working window drawn on the timeline. Set compress: false to draw
      # all 24 hours instead of just the working day.
      day_start: "07:00"
      day_end: "22:00"
      compress: true

    # The one thing the week is actually pointed at.
    goal:
      label: Ship the Q3 sonic brand package to client
      due: "fri 17:00"
      detail: Master bus + stems + 3 stingers delivered, invoice out same day.

    tasks:
      - id: mix-ep14
        title: Mixdown - Podcast Ep.14
        track: Studio
        start: "mon 09:00"
        duration: 4
        status: done
        owner: Xens

      - id: vo-pickup
        title: VO pickups - Safaricom spot
        track: Studio
        start: "mon 14:00"
        end: "mon 17:30"
        status: done

      - id: stems
        title: Stem prep + bounce
        track: Studio
        start: "tue 09:30"
        duration: 3.5
        status: done

      - id: stingers
        title: Cut 3 brand stingers
        track: Studio
        start: "wed 10:00"
        duration: 5
        status: in_progress
        progress: 0.55
        notes: Two down. Third needs the low-end rework.

      - id: master
        title: Master bus pass
        track: Studio
        start: "thu 09:00"
        duration: 4
        status: todo

      - id: api-deploy
        title: Deploy telemetry API v2
        track: Backend
        start: "tue 15:00"
        duration: 2.5
        status: done

      - id: webhook
        title: Client webhook + delivery receipts
        track: Backend
        start: "wed 16:00"
        duration: 3
        status: blocked
        notes: Waiting on their IT to whitelist the callback IP.

      - id: dash
        title: Wire dashboard to live job queue
        track: Backend
        start: "thu 14:00"
        duration: 3
        status: todo

      - id: review
        title: Client review call
        track: Client
        start: "thu 18:00"
        duration: 1
        status: todo

      - id: delivery
        title: Final delivery + invoice
        track: Client
        start: "fri 14:00"
        end: "fri 17:00"
        status: todo

      - id: retro
        title: Week retro + next slate
        track: Ops
        start: "fri 17:30"
        duration: 1
        status: todo
  YAML
end
