# Mission Control Dashboard

A local week-timeline dashboard as a Ruby gem: an hour-resolution Gantt chart,
live task telemetry, and a pending-goal countdown that also tells you whether
the work still fits in the hours you have left.

Driven by one plain YAML file. **No runtime gem dependencies** — it runs on
Ruby's standard library alone. No Rails, no Sinatra, no Rack, no Node, no
build step, no CDN. Nothing to install but the gem itself.

---

## Install

```bash
gem build mission_control_dashboard.gemspec
gem install mission_control_dashboard-2.3.0.gem
mission_control server
```

Then open <http://127.0.0.1:4567>.

Want to try it before building anything? From the unzipped folder:

```bash
ruby bin/mission_control server
```

That works straight out of the directory — no build, no install.

---

## Commands

| Command | What it does |
| --- | --- |
| `mission_control server` | Start the dashboard (default port 4567) |
| `mission_control open` | Start it and open your browser |
| `mission_control status` | Print live tasks, next up and the goal countdown to the terminal |
| `mission_control init` | Write a starter board (won't overwrite an existing one) |
| `mission_control doctor` | Check the environment and validate your board |
| `mission_control path` | Print the board file path |

Flags: `-p/--port`, `-H/--host`, `-b/--board`, `-q/--quiet`, `--read-only`,
`--engine sinatra`.

---

## The board file

Lives at `~/.mission_control/board.yml` (on Windows,
`C:\Users\you\.mission_control\board.yml`). Override it per-run:

```bash
mission_control server --board ./this_week.yml
MISSION_CONTROL_BOARD=./this_week.yml mission_control server
```

Edit the file, refresh the browser. That is the entire workflow — no restart,
no rebuild, no reinstall. The page also re-polls every 20 seconds on its own.

You can also edit from the browser (see [Editing](#editing) below). Both
directions write the same file; neither is the "real" one.

```yaml
meta:
  title: Mission Control
  operator: Xens
  day_start: "07:00"    # the working window drawn on the timeline
  day_end: "22:00"
  compress: true        # false = draw all 24 hours

goal:
  label: Ship the Q3 sonic brand package to client
  due: "fri 17:00"
  detail: Master bus + stems + 3 stingers, invoice out same day.

tasks:
  - id: stingers
    title: Cut 3 brand stingers
    track: Studio          # groups tasks into swim lanes
    start: "wed 10:00"
    duration: 5            # hours; or use `end:` instead
    status: in_progress    # todo | in_progress | blocked | done
    progress: 0.55         # 0.55 or 55 both work
    owner: Xens
    notes: Third one needs the low-end rework.

  - id: itw
    title: ITW Deliverables & Contract
    track: Client
    start: "mon 09:00"
    end: "fri 18:00"       # the WINDOW the work lives in
    effort: 8              # the HOURS it actually costs — see below
    checklist:             # ticked items derive progress automatically
      - "x Finalize Contract"
      - Lock in Deliverables
      - {title: Finalize Media Plan, done: true}
      - Internal Reviews
```

### `effort` vs `duration` — the distinction that matters

`start`/`end` describe a **window**. `effort` describes **hours of work**.
They are not the same number and confusing them wrecks the capacity tile.

"Open Mon → Fri" does not mean 45 hours of work; it means a five-day window
that might hold 8 hours of actual work. Without `effort`, eight such projects
sum to ~300 booked hours against a ~100 hour week and the capacity check
screams overcommitted for no real reason.

So: set `effort` on anything that is a window rather than a solid block.
Tasks with `effort` are drawn as **hollow dashed bars** with end caps — visually
distinct from solid booked blocks — and only their `effort` counts toward
capacity. Omit `effort` and it defaults to the span, which is right for a
meeting or a session that really does occupy its whole window.

### `checklist` — measured progress instead of felt progress

Self-reported `progress:` is famously optimistic. A `checklist` gives you a
number you can defend: **ticked items ÷ total**. Write items as plain strings
(unticked), prefix `x ` to tick one, or use `{title: ..., done: true}`.

An explicit `progress:` always wins if you set both. Checklist items show
inline on the task cards and in the bar tooltip.

## Editing

The dashboard is read-write. **+ Add task** opens the editor; clicking any bar,
task name or card opens it on that task. Checklist boxes on the cards tick with
one click, no dialog. Ctrl/Cmd-Enter saves, Esc closes.

Every save writes straight back to your YAML file.

### Your comments survive

This is the part worth trusting. The obvious implementation of "save from the
UI" is load-then-dump, which silently erases every comment in the file. A board
is a document you annotate — `# <-- ESTIMATE`, `# waiting on their IT` — and
losing those on first save would make the editor worse than a text editor.

So saving rewrites **only the line range of the task you touched**. Header
blocks, comments between tasks, trailing notes, and inline comments on tasks you
did not edit are all preserved byte for byte. The one exception: an inline
comment on a key inside a task you just edited goes away, because that block is
regenerated.

Before every write the file is copied to `board.yml.bak`, the result is parsed to
confirm it is still valid YAML, and only then swapped into place with an atomic
rename. A failed write leaves the original untouched.

### Conflicting edits are refused, not merged

Each response carries a revision token derived from the file's mtime and size.
If the file changed since the page loaded — you edited it in a text editor,
another tab saved, a script rewrote it — the save is rejected with a `409` and a
prompt to reload. It will not silently overwrite work it never saw.

### The security model

This server accepts writes, so it is deliberately hard to reach from anywhere
but your own browser:

- Binds to `127.0.0.1`. Nothing is exposed to your network by default.
- Writes are refused unless the `Host` header is a loopback address, which
  blocks DNS-rebinding attacks that point a public hostname at `127.0.0.1`.
- Writes require an `X-Mission-Control: 1` header. A cross-origin form POST
  cannot set a custom header without a CORS preflight, and this server never
  sends CORS headers — so a random web page you happen to have open cannot
  edit your board.
- Only known keys are written. Anything else in the payload is dropped rather
  than smuggled into your file.
- `--read-only` disables all writes and hides the UI's edit controls.

There is no authentication, because there are no accounts. If you run this on
`--host 0.0.0.0`, anyone who can reach the port and set one header can edit
your board. Use `--read-only` if you want to put it on a wall display.

### API

| Route | Does |
| --- | --- |
| `POST /api/tasks` | create — body `{rev, task: {...}}` |
| `PATCH /api/tasks/:id` | update the given fields only |
| `DELETE /api/tasks/:id` | remove |

All three require the `X-Mission-Control: 1` header and return
`{ok, id, rev}` or `{ok: false, error}` with a `409` (stale rev) or `422`
(validation) status.

### Time syntax

| You write | It means |
| --- | --- |
| `"mon 09:00"` | Monday of whichever week you're viewing |
| `"today 14:00"` | today |
| `"tomorrow 09:30"` | tomorrow |
| `"2026-08-14 17:00"` | pinned to that real calendar date |

Weekday-relative times are the useful default: a board written with `mon`/`tue`
never goes stale, and the `←` / `→` buttons walk it forward or back a week.

---

## What the numbers mean

**Capacity to goal** is the tile worth reading twice. It compares:

- **work left** — every unfinished task's duration, discounted by its declared
  progress (a 4h task at 50% counts as 2h)
- **capacity** — the actual working hours between *now* and the goal's due
  time, counting only your `day_start`–`day_end` window each day

If work left exceeds capacity, the tile turns red and tells you by how much.
A countdown alone tells you time is passing; this tells you whether the plan
is arithmetically possible. It is a scheduling constraint, not a judgement —
the fix is always to cut scope, move the date, or delegate.

**Task states** are derived, not stored:

| State | When |
| --- | --- |
| `done` | you marked it done |
| `blocked` | you marked it blocked |
| `overdue` | its window closed and it isn't done |
| `live` | you marked it `in_progress`, **or** now is inside its window |
| `upcoming` | everything else |

Marking something `in_progress` beats the calendar — if you're working on
Thursday's task on Tuesday, the board believes you, not the schedule.

---

## Timeline controls

- **← / →** — previous / next week (relative tasks move with you)
- **Zoom slider** — pixels per hour; the default auto-fits the week to your screen
- **Work hours** — compress each day to `day_start`–`day_end`, or show all 24
- **7 days** — weekends are hidden unless something is booked on them; this forces them back

Hover any bar for the full window, status, progress, owner and notes.

---

## Endpoints

| Route | Returns |
| --- | --- |
| `/` | the dashboard |
| `/api/board?week=N` | the full computed board as JSON |
| `/healthz` | `{"ok":true}` |

`/api/board` is the integration point. It returns resolved timestamps, derived
states, and the whole capacity calculation — enough to drive a second display,
a Slack bot, or a status LED, without reimplementing any of the date logic.

---

## If it ever stops responding

The server used to be able to freeze: alive, accepting TCP connections,
answering none of them. Root cause was that every request wrote a log line
**before** its response, and writing to a console is not guaranteed to be fast.

On Windows, clicking inside the console window starts a Quick Edit text
selection, and Windows suspends every write to that console until you press
Esc. The process is not paused — only its output. But because the log came
first, one click froze every request behind it.

Fixed in 2.3.0:

- **Logging can no longer block a response.** Request threads push onto a
  bounded queue and move on; a single writer thread does the blocking part.
  If output stalls, log lines are *dropped* and counted, never queued forever.
  When it recovers it prints how many were lost.
- **The response is written before anything is logged.**
- **Every read has a deadline.** A client that connects and says nothing is
  dropped after 15 seconds instead of pinning a thread and a file descriptor.
- **Concurrency is capped** at 64 connections; past that the server sheds with
  a `503` rather than exhausting the process.
- **The accept loop survives** running out of file descriptors and failing to
  create threads, instead of dying and leaving a listening-but-dead socket.

If the browser ever shows stale data, the page now says so with a banner rather
than displaying old numbers as though they were live.

To check the server from another terminal:

```bash
curl http://127.0.0.1:4567/healthz
```

```json
{"ok":true,"version":"2.3.0","pid":8123,"threads":3,
 "active":1,"served":412,"shed":0,"logs_dropped":0}
```

`active` is in-flight connections, `served` is the lifetime count, `shed` is
requests rejected at the concurrency cap, and `logs_dropped` is non-zero if
output was blocked — which on Windows means: click the console, press Esc.

## Notes

- Binds to `127.0.0.1` by default — nothing is exposed to your network. Use
  `--host 0.0.0.0` deliberately if you want it on the LAN, and understand that
  it has no authentication.
- Sinatra is supported but optional: `gem install sinatra` then
  `mission_control server --engine sinatra`. There is no reason to unless you
  intend to add middleware.
- Requires Ruby >= 3.0.

## Development

```bash
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require File.expand_path(f) }'
```

60 tests cover time parsing, state derivation, the capacity maths, malformed
YAML, HTML escaping, the socket server end to end, comment-preserving writes,
revision conflicts, and every rejection path on the write API.

MIT licensed.
