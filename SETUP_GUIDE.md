# Sentinel-V1 — Step-by-step: copy → fix → auto-updater → deploy

**Recommended order: fix first, then deploy.** The auto-updater public key and the
bundle identifier are compiled into every installer. The *first* release users
install must already contain them, otherwise those users can never auto-update,
and changing the identifier later orphans their installed app data. Do all of
Parts 1–4 before cutting a release in Part 5.

Commands below assume macOS/Linux shell. On Windows use Git Bash or PowerShell
equivalents.

---

## Part 1 — Copy the workflow into Sentinel-V1

```bash
# 1. Clone both repos side by side (skip clones you already have)
git clone https://github.com/Xensfromtheeast/Claude_bckp.git
git clone https://github.com/Xensfromtheeast/Sentinel-V1.git

# 2. Check out the branch that has the workflow
cd Claude_bckp
git checkout claude/sentinel-v1-deployment-gx2cpp

# 3. Copy the workflow (and optionally the docs) into Sentinel-V1
mkdir -p ../Sentinel-V1/.github/workflows
cp .github/workflows/release.yml ../Sentinel-V1/.github/workflows/release.yml
cp DEPLOYMENT.md                 ../Sentinel-V1/DEPLOYMENT.md   # optional
cd ../Sentinel-V1
```

Don't commit yet — apply the fixes below first so it's all one clean change.

---

## Part 2 — Apply the config fixes

Edit `src-tauri/tauri.conf.json`.

### 2a. Real bundle identifier
```diff
- "identifier": "com.tauri.dev",
+ "identifier": "com.xensfromtheeast.sentinel",
```

### 2b. Content Security Policy (replace the `null`)
Under `app.security`:
```jsonc
"security": {
  "csp": "default-src 'self' asset: http://asset.localhost; img-src 'self' asset: http://asset.localhost data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' ipc: http://ipc.localhost"
}
```
> `'unsafe-inline'` for styles is needed because Svelte injects component
> styles. After applying, run `npm run tauri dev` and watch the devtools
> console — if anything is blocked, loosen only the specific directive.
> (The updater fetches over Rust-side HTTP, so the endpoint does **not** need
> a CSP entry.)

---

## Part 3 — Set up the auto-updater

### 3a. Ensure the Tauri CLI is available
```bash
npm install --save-dev @tauri-apps/cli@^2
```

### 3b. Add the updater (and process, for relaunch) plugins
```bash
npx tauri add updater
npx tauri add process
```
This edits `src-tauri/Cargo.toml`, installs `@tauri-apps/plugin-updater` +
`@tauri-apps/plugin-process`, registers both plugins in `src-tauri/src/lib.rs`,
and adds permissions to `src-tauri/capabilities/default.json`. Verify
`lib.rs` contains:
```rust
.plugin(tauri_plugin_updater::Builder::new().build())
.plugin(tauri_plugin_process::init())
```
and `src-tauri/capabilities/default.json` includes `"updater:default"`,
`"process:default"`, `"process:allow-relaunch"`.

### 3c. Generate the updater signing key pair
```bash
npx tauri signer generate -w ~/.tauri/sentinel.key
```
This prints/creates:
- a **private** key (`~/.tauri/sentinel.key`) — secret, used by CI to sign,
- a **public** key — paste into config below. Set a password when prompted
  (remember it; it's a CI secret too).

### 3d. Tell Tauri to produce updater artifacts + where to look for updates
In `src-tauri/tauri.conf.json`:

```jsonc
"bundle": {
  "active": true,
  "targets": "all",
  "createUpdaterArtifacts": true        // <-- add this (required in Tauri 2)
},
"plugins": {
  "updater": {
    "pubkey": "PASTE_THE_PUBLIC_KEY_HERE",
    "endpoints": [
      "https://github.com/Xensfromtheeast/Sentinel-V1/releases/latest/download/latest.json"
    ]
  }
}
```

### 3e. Add an update check in the frontend
Example (TypeScript) — call this on app start or behind a "Check for updates" button:
```ts
import { check } from '@tauri-apps/plugin-updater';
import { relaunch } from '@tauri-apps/plugin-process';

export async function checkForUpdates() {
  const update = await check();
  if (update) {
    await update.downloadAndInstall();
    await relaunch();
  }
}
```

---

## Part 4 — Add GitHub secrets and enable signing in CI

1. In Sentinel-V1: **Settings → Secrets and variables → Actions → New repository secret**:
   | Secret | Value |
   |--------|-------|
   | `TAURI_SIGNING_PRIVATE_KEY` | full contents of `~/.tauri/sentinel.key` |
   | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | the password you set (leave blank if none) |

2. In `.github/workflows/release.yml`, uncomment the two updater lines under `env:`:
   ```yaml
   TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
   TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
   ```
   With these set and `createUpdaterArtifacts: true`, `tauri-action` signs the
   bundles and uploads `latest.json` to the release automatically — which is
   exactly what the endpoint in 3d points to.

> macOS/Windows OS-level code signing (to remove "unknown developer" warnings)
> is separate and optional — see DEPLOYMENT.md §5. The updater works without it.

---

## Part 5 — Commit, tag, and release

```bash
# Keep all version fields in sync with the tag
#   src-tauri/tauri.conf.json  -> "version"
#   package.json               -> "version"
#   src-tauri/Cargo.toml       -> version

git add .github/workflows/release.yml DEPLOYMENT.md src-tauri package.json package-lock.json
git commit -m "Add release CI/CD, auto-updater, identifier + CSP fixes"
git push origin main

# Cut the release
git tag v0.1.0
git push origin v0.1.0
```

The workflow runs the build matrix (Windows / macOS x2 / Linux) and creates a
**draft** GitHub Release with installers + `latest.json`. Open **Releases**,
review the assets, then **Publish**.

---

## Part 6 — Verify auto-update works

1. Install the **v0.1.0** build on a machine.
2. Bump versions to `0.1.1`, commit, then `git tag v0.1.1 && git push origin v0.1.1`.
3. Publish the new draft release.
4. Launch the installed v0.1.0 app and trigger `checkForUpdates()` — it should
   find v0.1.1 via `latest.json`, download, install, and relaunch.

---

## Quick checklist

- [ ] `release.yml` copied to `Sentinel-V1/.github/workflows/`
- [ ] identifier changed from `com.tauri.dev`
- [ ] real CSP set (tested with `tauri dev`)
- [ ] `npx tauri add updater` + `process` run and verified in `lib.rs`/capabilities
- [ ] signing keypair generated; pubkey in `tauri.conf.json`
- [ ] `createUpdaterArtifacts: true` set
- [ ] updater `endpoints` set to the Releases `latest.json` URL
- [ ] frontend update check added
- [ ] `TAURI_SIGNING_PRIVATE_KEY` + password secrets added in GitHub
- [ ] updater `env:` lines uncommented in `release.yml`
- [ ] versions synced; tag pushed; draft release published
- [ ] update from v0.1.0 → v0.1.1 verified
```
