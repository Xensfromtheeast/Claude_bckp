# claude_bckp

Staging area for work produced by Claude Code.

## Contents

### Mission Control Dashboard (Ruby gem, v2.3.0)

A local week-timeline dashboard: hour-resolution Gantt, live task telemetry,
a pending-goal countdown with a capacity check, and browser-based editing
that writes back to YAML. Zero runtime dependencies — Ruby stdlib only.

- `mission_control_dashboard/` — the gem source (staged here as-is from the
  built and tested v2.3.0 release; 60 tests passing)
- `mission_control_dashboard/FEATURE_ANALYSIS.md` — analysis of proposed
  next features (structured date/time pickers, a history/archive feature,
  user profiling, AI chat-import) against the current architecture

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
