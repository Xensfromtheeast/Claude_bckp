# claude_bckp

Staging area for work produced by Claude Code.

## Contents

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
