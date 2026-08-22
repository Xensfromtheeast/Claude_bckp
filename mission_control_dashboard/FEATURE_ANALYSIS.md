# Task Analysis and Feature Implementation — Mission Control Dashboard v2.3.0

This is a design analysis, not a changelog: it evaluates the enhancements
proposed for the dashboard against the actual v2.3.0 codebase (`lib/`,
`week.yml`) and recommends what to build and in what order. No code in this
gem was changed to produce it.

## I. Introduction

The dashboard does one thing well today: it turns a single YAML file into a
week-scale Gantt with a goal-capacity check, and writes edits back to that
same file without disturbing comments. Everything proposed below is an
extension of that model, not a replacement for it. The features fall into two
groups by how well-specified they are:

- **Buildable now** — enhanced task creation (II) and a history feature (III)
  have clear inputs, clear outputs, and slot into the existing YAML-in,
  YAML-out architecture.
- **Needs a product decision first** — user profiling (V) and AI chat
  ingestion (VI) require choices (what gets stored, where, whether the
  process ever talks to a network) that are the operator's to make, not
  inferable from the current code. Section IV lays out what the codebase can
  and cannot support today so those decisions are informed ones.

## II. Enhanced Task Creation

### A. Current limitations

The add/edit form (`view.rb:304-346`) takes start and end as free text:

```html
<input id="f-start" type="text" placeholder="mon 09:00" autocomplete="off">
<input id="f-end"   type="text" placeholder="tue 18:00" autocomplete="off">
```

That string is parsed by `Board#parse_time_string` (`board.rb:406-428`),
which recognizes three shapes: a weekday keyword (`mon`, `tue`, ...) plus an
optional time, `today`/`tomorrow`/`yesterday` plus an optional time, or a
fallback to Ruby's `Time.parse` for anything else (so `"2026-08-14 17:00"`
also works). A typo — `"mnoday 9"`, `"tues 9:00"` — is not caught until
submit, where `App#validate` calls `board.readable_time?` and returns a
generic "Could not read start" error (`app.rb:216-223`). Nothing in the form
constrains what can be typed; the day-of-week vocabulary and time-format
tolerance live only in the parser and the error message.

### B. Proposed solution

Replace the two free-text inputs with structured pickers that still resolve
to the same string the backend already accepts — this is a UI change, not a
protocol change:

- A day selector: either the seven weekday buttons the parser already
  understands, or a native `<input type="date">` for pinning to a real
  calendar date (the `"2026-08-14 17:00"` form). Both should stay available —
  weekday-relative is what makes a board reusable week over week (see the
  `readme`'s "never goes stale" point); absolute dates are what a history
  feature (III) actually needs to keep entries from drifting when the viewed
  week changes.
- A time selector: `<input type="time">` (or two `<select>`s for hour/minute
  if finer step control is wanted) instead of typed `HH:MM`.
- Client-side, compose the two into the exact string format
  `parse_time_string` already parses (`"mon 09:00"` or
  `"2026-08-14 17:00"`), so `board.rb` needs no changes at all. The only
  other touch point is `view.rb:819-825`, which currently *reads* a task's
  resolved time back into the free-text field on edit (`$('f-start').value =
  DAYS[...] + ' ' + hhmm(s)`) — that becomes pre-selecting the picker instead
  of formatting a string.

Benefits: eliminates the entire class of "could not read start" typos,
removes the need to memorize the weekday-abbreviation vocabulary, and — if
absolute-date pinning is exposed as a first-class option in the picker rather
than something you have to know to type — makes pinned-date tasks (needed for
III) as easy to create as relative ones.

This is UI-only and additive: `validate()`'s existing `readable_time?` check
stays as a server-side backstop for anyone hitting the API directly, and no
existing board file needs migration.

## III. History Feature Development

### A. Importance

A capacity tool that only ever shows the current week has no memory —
you can't compare planned effort to what actually got done, or carry a
`checklist` forward if a task really did slip. The outline's ask (log a
task completed the previous week) is really asking for two related things:
adding an entry that lives in the past, and being able to look back at what
a prior week actually contained.

### B. What the current architecture supports — and doesn't

This is the load-bearing finding for this section: **`week.yml` does not
currently store history, and the `←`/`→` week-navigation buttons do not
reveal it either.**

Walk through why. `Board#snapshot` takes a `week_offset` and computes
`week_start` from it (`board.rb:78-91`). Every task's `start`/`end` is then
resolved *against that `week_start`* (`parse_time`, called from
`build_tasks`). For a weekday-relative task like `"mon 09:00"`, that means
the exact same task in `week.yml` is redrawn on **every** week you page to —
last week, this week, next week all show `itw-deliverables` running Monday
to Tuesday, because nothing in the file pins it to one specific calendar
week. Paging back with `←` is not "what did I actually do last week", it's
"what would this recurring template look like if this week were shifted".

Only a task whose `start`/`end` is an absolute date
(`"2026-08-14 17:00"`) is anchored to one real week. A task like that,
marked `status: done`, would still show up when you page forward to future
weeks too — `build_tasks` has no notion of "this task belongs only to the
week containing its date" and doesn't filter by `week_offset` at all; it
just re-resolves every task's time string against whatever `week_start` is
current. So even absolute-dated done tasks accumulate in the file forever
and appear on every week view, which is not what a history feature needs
either.

There is also no second file anywhere in the gem for past goals. `Board`
reads exactly one path (`Board.default_path`, `board.rb:24-29`:
`~/.mission_control/board.yml`, or `$MISSION_CONTROL_BOARD`); nothing else
in `cli.rb` or `seed.rb` reads or writes a second file. "Other files that
may hold past weekly goals" — there are none; a goal (`meta.goal`) is a
single mutable value in the one live file, overwritten whenever it's edited,
with no version kept of what it was last week.

### C. Proposed design

Two additive pieces, both consistent with the "one plain YAML file, comment
preserving" philosophy rather than replacing it:

1. **Archiving.** A new `mission_control archive` CLI command (alongside the
   existing `server | open | init | status | doctor | path` in `cli.rb`)
   that copies the *current* week's resolved snapshot (not the raw file — the
   raw file has relative dates that won't mean anything later) into
   `history/<iso-year>-W<iso-week>.yml` under the same directory as the board
   file, tagged with absolute dates. This reuses `Writer`'s existing
   atomic-write-plus-`.bak` machinery; it doesn't need the comment-preserving
   surgical edit path since archives are write-once snapshots, not
   documents someone hand-edits.
2. **Read-only history browsing.** A `/api/history` route returning the list
   of archived weeks, and a lightweight read-only view (or a `week=` value
   that means "archived", separate from the current best-effort
   `week_offset` paging) so the dashboard can show a past week exactly as it
   was, rather than replaying relative-day tasks against a different
   calendar week. This is a read path only — the `write_guard` / revision
   token machinery in `app.rb` that protects live edits doesn't need to
   apply to history at all.

Logging a single past task without a full archive (the outline's literal
"add a task completed last week" ask) is a smaller version of the same fix:
the add-task form from section II, with the date picker pointed at a past
date and `status: done` preselected, already produces a valid absolute-dated
entry today — no backend change required for that narrow case. The
architectural gap is specifically that paging `←` does not currently show
you a faithful past week, and nothing prunes or separates old dated tasks
from the live board.

## IV. System Architecture

### A. `week.yml` (the outline calls it `board.yml` — same file, this
   installed board happens to be named `week.yml`)

Three top-level keys, all optional except `tasks`:

- `meta` — `title`, `operator`, `day_start`/`day_end` (the working-hours
  window drawn on the timeline and used for the capacity math), `compress`.
- `goal` — `label`, `due`, `detail`. Absent or incomplete, the countdown and
  capacity tiles go dark (`build_goal`, `board.rb:308-345`, returns
  `{"set" => false}`).
- `tasks` — a list of hashes. Per task: `title`, `track` (swim lane),
  `start`/`end` (or `duration`/`hours` as an alternative to `end`),
  `effort` (hours, feeds capacity — see the `effort`-vs-`duration`
  distinction called out at length in both the file's own header comment
  and `board.rb:161-170`), `status` (`todo | in_progress | blocked | done`),
  `progress` (0–1 or 0–100, explicit override), `checklist` (derives
  progress as ticked ÷ total when `progress` isn't set — `progress_for`,
  `board.rb:238-252`), `owner`, `notes`.

Everything derived — `state` (`done | live | overdue | blocked | upcoming`),
resolved ISO timestamps, per-track grouping, and the whole capacity
calculation — is computed fresh on every `snapshot` call and never written
back to the file. Only the fields a person or the editor sets are persisted;
this is what keeps the YAML both human-editable and safe to page through at
different `week_offset`s.

### B. Other files holding past weekly goals

None exist. See III.B above — this is the direct answer to that open
question, not a separate finding.

### C. AI integration for Life Coaching — pointer

Deferred to section VI, which covers it directly (ingesting shared AI chat
summaries) rather than duplicating the discussion here. The one
architectural note worth surfacing early: the gem's current zero-dependency,
loopback-only, no-CORS security posture (`README.md`'s "The security model"
section, `app.rb:19-22,72-90`) is a deliberate choice, and any AI feature
that talks to a network service is a departure from it that should be
opt-in, not default — expanded on in VI.C.

## V. User Profiling and Personalization

This section is scoped as analysis only — it is a genuinely separate product
surface from "a YAML file that draws a Gantt chart," and building it without
first deciding what gets asked, where it's stored, and how private it needs
to be would mean guessing at decisions that are the operator's to make.

### A. Why it would matter

A capacity check already tells you whether a week's plan is arithmetically
possible. It cannot tell you whether the plan is a *good* one — whether the
tasks in `week.yml` actually serve whatever the person using this is trying
to get out of their week. That requires context the board file doesn't
carry today: what this person's work actually is, what else is competing for
their time, what they're bad at sticking to.

### B. What such a profile would need to capture

At minimum: work life (what "Client"/"Studio"/"Ops" tracks — the swim lanes
already in `week.yml` — actually mean for this person), personal-life
constraints that compete with the same hours the capacity check is counting,
known failure modes ("vices" in the outline's language — recurring slippage
patterns worth flagging rather than moralizing about), and standing
strengths worth routing work toward.

### C. Where it would need to live

Consistent with the rest of the gem's model (one plain, human-editable,
comment-preserving YAML file), a profile is a natural second file —
`profile.yml` beside `board.yml` — rather than a field bolted onto the board
itself; a profile answers "who is this for" once, not per week. It should
stay local-only by default, same as the board: nothing about this needs a
network round-trip to be useful, and the existing security model (loopback
bind, no CORS, explicit anti-CSRF header) should extend to it rather than be
carved out for it.

### D. Goal alignment

The natural connection point is `meta.goal` and the capacity tile: once a
profile exists, a task or goal that's clearly misaligned with it (wrong
track for this person's stated work, competing with a known personal-life
constraint) becomes something the dashboard could flag the same way it
already flags an over-capacity week — a warning surfaced in `warnings`, not
a task it silently rejects.

Before any of this is built: what fields, what onboarding flow, and how much
of it (if any) should ever leave the machine are open questions this
analysis is deliberately not answering on the operator's behalf.

## VI. AI Integration for Task Management

Also analysis-only, for the same reason as V — and it directly implicates
the "local vs. network" question the outline itself raises.

### A. Shared AI chats as input

The idea — point the tool at a markdown export or link from a Gemini/Claude
conversation and have it propose tasks — is a plausible import path. The
useful boundary: the *output* of that process is exactly a set of task
hashes matching the schema in IV.A (title, track, start/end or effort,
checklist), because that's what `Writer` already knows how to write
correctly, comments and all. The AI's job would be producing candidate task
dicts; it should not be given write access itself — the existing
`POST /api/tasks` path, with its `validate()` and allow-listed `EDITABLE`
keys (`app.rb:170-184`, `writer.rb:30`), is already the correct choke point
for "something proposes a task, the board decides whether to accept it."

### B. Analysis capabilities

Concretely, this means: feed chat markdown to an LLM with the task schema
as its output contract, get back a list of candidate tasks (very plausibly
*without* `effort` filled in confidently — the gem's own `week.yml` shows
every AI-estimated `effort:` value flagged `<-- ESTIMATE` for exactly this
reason, per the "Open threads" note in the project's own history), and
surface them for one-click accept/edit/discard in the browser rather than
writing them straight to the board. Auto-suggesting future goals from
completed-task patterns is the same idea run over history data (III) instead
of a chat export.

### C. Local vs. network functionality

This is the one place a hard line matters. The gem's core identity — as
stated in its own README and gemspec — is zero runtime dependencies,
stdlib-only, nothing reaching outside `127.0.0.1` by default. An AI feature
by definition needs to call *something* with more reasoning capacity than
what fits in a dependency-free Ruby script, which means it cannot be part of
that default posture. The precedent already exists in this codebase for
exactly this shape of optionality: Sinatra is "supported but optional" — a
separate `--engine sinatra` flag that does nothing unless explicitly
requested (`server.rb`, README's "Notes" section). An AI import feature
should follow the same pattern: off by default, explicit opt-in (a flag or a
separate command), and clearly documented as the one place this tool talks
to a network, rather than quietly expanding what "local dashboard" means.

## VII. Conclusion

Two of the six proposed enhancements are ready to build against the current
codebase with no architectural surprises:

- **II — structured date/time pickers.** UI-only; the backend's time parser
  and validation already accept everything the pickers would produce.
- **III — history.** Needs one new concept (an archive snapshot, taken with
  absolute dates, separate from the live relative-dated board) plus a
  read-only view for it; the single biggest finding here is that week
  navigation today does *not* show real history, so this is filling a gap
  rather than exposing one that already half-exists.

Section IV answered the outline's own open questions about the data model:
`week.yml`'s structure is as documented, and no other file currently stores
past goals — that absence is precisely what III proposes to fix.

V and VI are real product directions, not just implementation details, and
building them now would mean this analysis making decisions (what a profile
asks, where AI-generated tasks get reviewed before they touch the board,
whether network access is ever on by default) that belong to whoever runs
this dashboard. The concrete recommendation: ship II and III first — they
compound (a picker that can pin absolute dates is what makes clean history
entries easy to create), then come back to V and VI as their own scoped
specs once the profile/AI-provider questions have actual answers.
