# claude_bckp

Staging area for work produced by Claude Code.

## Contents

### Mission Control Dashboard (Ruby gem, v2.4.0)

A local week-timeline dashboard: hour-resolution Gantt, live task telemetry,
a pending-goal countdown with a capacity check, and browser-based editing
that writes back to YAML. Zero runtime dependencies — Ruby stdlib only.

- `mission_control_dashboard/` — the gem source (83 tests passing). v2.4.0
  adds phase one of the feature analysis: structured date/time pickers in
  the editor, week archiving with real read-only history views, and a
  local-only `profile.yml` that personalises the board's warnings
- `mission_control_dashboard/FEATURE_ANALYSIS.md` — the design analysis the
  phase-one work implements; section VI (AI chat-import) remains a proposed
  follow-up

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
