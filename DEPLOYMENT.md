# Sentinel-V1 — Deployment (GitHub Release CI/CD)

This folder contains a GitHub Actions workflow that builds **Sentinel** desktop
installers for Windows, macOS (Apple Silicon + Intel) and Linux, and publishes
them to a **GitHub Release**.

> **Why "release" and not "deploy"?** Sentinel-V1 is a **Tauri 2** desktop app
> (SvelteKit + TypeScript frontend, Rust backend). There is no server to deploy
> to — distribution means building native installers and attaching them to a
> tagged GitHub Release that users download.

These files were produced in the `claude_bckp` repo. The workflow lives at the
exact path it needs in the target repo, so deployment = copying it over.

---

## 1. Install into the Sentinel-V1 repo

Copy the workflow into the Sentinel-V1 repository, preserving the path:

```
.github/workflows/release.yml   ->   Sentinel-V1/.github/workflows/release.yml
```

Commit and push it to Sentinel-V1's default branch. No further setup is required
for an **unsigned** release — `GITHUB_TOKEN` is provided automatically by Actions.

---

## 2. Cut a release

The workflow triggers on any tag matching `v*`. From the Sentinel-V1 repo:

```bash
# Make sure src-tauri/tauri.conf.json "version" matches the tag you cut.
git tag v0.1.0
git push origin v0.1.0
```

Or run it manually: **Actions → Release → Run workflow**.

What happens:
1. A matrix job spins up on macOS, Ubuntu 22.04 and Windows runners.
2. Each installs deps, runs `npm run build` (the Tauri `beforeBuildCommand`),
   then `tauri build`.
3. `tauri-apps/tauri-action` collects the bundles and uploads them to a
   **draft** GitHub Release named after the tag.

Built artifacts:

| Platform | Files |
|----------|-------|
| Windows  | `.msi`, `.exe` (NSIS) |
| macOS    | `.dmg`, `.app.tar.gz` (one per arch: aarch64 + x86_64) |
| Linux    | `.AppImage`, `.deb` |

4. Review the draft under **Releases**, then click **Publish**.
   (Set `releaseDraft: false` in `release.yml` if you'd rather publish
   automatically.)

---

## 3. Project prerequisites (verify in Sentinel-V1)

The workflow assumes the current Sentinel-V1 layout. Confirm these still hold:

- **`package-lock.json` is committed.** The workflow uses `npm ci` (and npm
  caching). If there's no lockfile, change `npm ci` to `npm install` and drop
  `cache: npm` in `release.yml`.
- **`@tauri-apps/cli` is available.** `tauri-action` runs the Tauri build
  directly, but for reproducible local/CI builds add it to `devDependencies`:
  ```bash
  npm install --save-dev @tauri-apps/cli@^2
  ```
- **`beforeBuildCommand` is `npm run build`** and **`frontendDist` is `../build`**
  in `src-tauri/tauri.conf.json` — both are already set. Ensure the SvelteKit
  `adapter-static` output actually lands in `build/`.
- **Bundle `targets` is `"all"`** — already set; each runner produces its
  native formats.

---

## 4. Recommended fixes before a public release

These aren't required for CI to run, but matter for a real distribution:

- **Bundle identifier** is the placeholder `com.tauri.dev` in
  `src-tauri/tauri.conf.json`. Change it to something you own, e.g.
  `com.xensfromtheeast.sentinel`. Installers and OS integration key off this.
- **Content Security Policy** is `null`. Set a real CSP in
  `tauri.conf.json → app.security.csp` before shipping.
- **Keep versions in sync.** The git tag, `tauri.conf.json` `version`, and
  ideally `package.json`/`Cargo.toml` should all match for each release.

---

## 5. Optional: code signing, notarization & auto-update

The workflow ships unsigned by default. Users will see OS "unknown developer"
warnings. To remove those and/or enable in-app updates, add the relevant
GitHub **Secrets** and uncomment the matching `env:` lines in `release.yml`.

### macOS code signing + notarization
| Secret | Purpose |
|--------|---------|
| `APPLE_CERTIFICATE` | base64 of your `.p12` Developer ID cert |
| `APPLE_CERTIFICATE_PASSWORD` | password for the `.p12` |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple account email |
| `APPLE_PASSWORD` | app-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

### Windows code signing
Provide an Authenticode certificate and configure
`bundle.windows.certificateThumbprint` (or use Azure Trusted Signing) per the
Tauri Windows signing guide.

### Tauri auto-updater (optional)
1. Generate a key pair: `npm run tauri signer generate -- -w ~/.tauri/sentinel.key`
2. Add the **public** key to `tauri.conf.json → plugins.updater.pubkey` and set
   an updater endpoint (e.g. the GitHub Releases `latest.json`).
3. Add secrets `TAURI_SIGNING_PRIVATE_KEY` and
   `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, then uncomment them in `release.yml`.
   `tauri-action` will emit the `latest.json` update manifest alongside the
   installers.

See the Tauri v2 docs: <https://v2.tauri.app/distribute/> and
<https://v2.tauri.app/plugin/updater/>.
