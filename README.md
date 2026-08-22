# claude_bckp

Staging area for work produced by Claude Code.

## Contents

### Mission Control Dashboard (Ruby gem, v2.5.0)

A local week-timeline dashboard: hour-resolution Gantt, live task telemetry,
a pending-goal countdown with a capacity check, and browser-based editing
that writes back to YAML. Zero runtime dependencies — Ruby stdlib only.

- `mission_control_dashboard/` — the gem source (130 tests passing)
  - **v2.4.0** — structured date/time pickers, week archiving with real
    read-only history views, and a local-only `profile.yml` that
    personalises the board's warnings
  - **v2.5.0** — chat import: turn a shared AI chat into candidate tasks,
    offline by default, with an optional `--ai` path. Everything lands in a
    review queue first; nothing writes to the board unreviewed
- `mission_control_dashboard/FEATURE_ANALYSIS.md` — the design analysis both
  phases implement

### Sentinel-V1 deployment (GitHub Release CI/CD)

A GitHub Actions release pipeline for the
[Sentinel-V1](https://github.com/Xensfromtheeast/Sentinel-V1) Tauri desktop app.
It builds Windows / macOS (Apple Silicon + Intel) / Linux installers on a version
tag and publishes them to a GitHub Release.

- `.github/workflows/release.yml` — the release workflow
- `DEPLOYMENT.md` — how to install it into Sentinel-V1, cut a release, and
  (optionally) set up signing, notarization and auto-update

> These files target the **Sentinel-V1** repo. This session's write access is
> scoped to `claude_bckp`, so they're staged here — copy `.github/workflows/`
> into Sentinel-V1 to deploy. See `DEPLOYMENT.md`.
