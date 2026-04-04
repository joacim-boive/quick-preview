# Quick Preview Video Loop

macOS standalone video player focused on fast preview and loop workflows:

- Full-file loop toggle
- Precise seek controls (fine/coarse and Shift+arrow frame-step)
- High-resolution scrubber
- Standalone player app

## Project Layout

- `QuickPreview.xcodeproj`: Xcode project for the standalone app target.
- `Sources/Shared`: Shared playback engine and loop/seek logic.
- `Sources/App`: Standalone app and hotkey manager.
- `Sources/Resources`: App Info.plist.

## Controls

- `Space`: Play/pause for the current clip, including from the bookmark manager unless a text field is being edited
- `L`: Toggle full-video looping
- `Left/Right`: Fine seek (`0.1s`)
- `Shift+Left/Shift+Right`: Coarse seek (`1.0s`)
- `Option+Up/Option+Down`: Jump to the next/previous bookmark on the current clip
- `Up/Down`: Move through bookmarks while the bookmark manager is open
- `Shift+Up/Down`: Frame step (+/- one frame, with fine-step fallback)
- `Set Start` / `Set End`: Mark replay selection points
- `Replay Selection`: Loop only the marked segment
- `Clear Selection`: Remove current replay segment

## Bookmark Timeline Markers

- The main player timeline shows thin markers for every saved bookmark on the currently loaded clip.
- Opening a clip from any bookmark still shows markers for the clip's other bookmarks right away.
- Click a bookmark marker once to select it, then drag it to retime that bookmark.
- Dragging a selected bookmark marker previews the new position live and saves the bookmark plus its thumbnail frame on release.

## Editions

QuickPreview now supports two distribution paths:

- `Release`: Mac App Store-safe edition with the core player, bookmarks, clip memory, and protected-media workflows.
- `Pro`: direct-distribution edition for active subscribers who also want Finder live-follow.

The App Store edition remains the billing source of truth. The PRO edition uses a mirrored unlock token delivered through the website bridge flow in `site/pro/` and `api/bridge/`.

## Website and subscriber bridge (Vercel)

The whole Git repo is correct to connect to Vercel, but the **Vercel project root must be the repository root** (not `site/`). The build runs **`npm run build`**, which copies `site/` into **`public/`** for static hosting. Serverless routes must stay at **`api/bridge/`** relative to that same root. `vercel.json` sets **`outputDirectory`: `public`**, **`buildCommand`**, and a short **`maxDuration`** on the bridge routes.

### If the homepage is wrong or `/api/bridge/*` is 404

In **Project → Settings → General**:

- **Root Directory** — leave **empty** (or `.`). If you set this to `site`, Vercel never sees `api/`, so the bridge breaks. The app source HTML stays in `site/`; only the **build output** is `public/`.

In **Project → Settings → Build & Deployment**:

- **Framework Preset** — **Other** (or let `vercel.json` drive the build).
- **Build Command** — `npm run build` (or enable **“Use vercel.json”** / clear overrides so `vercel.json` is used).
- **Output Directory** — `public` (or rely on `vercel.json` and clear conflicting dashboard values).

After fixing settings, run **Redeploy** on the latest commit.

### One-time: Vercel project and env

1. [Create a project](https://vercel.com/new) from this Git repo (or run `vercel link` locally after `vercel login`).
2. In **Project → Settings → Environment Variables**, add for **Production** (and **Preview** if you test linking on preview URLs):
   - **`QUICKPREVIEW_BRIDGE_SECRET`** — long random string (server-only; signs link codes and PRO tokens).
   - **`QUICKPREVIEW_SITE_URL`** — `https://quickpreview.boive.se` so bridge responses use your canonical host (previews fall back to `VERCEL_URL` when unset).
3. **Project → Settings → Domains**: add `quickpreview.boive.se` and point DNS as instructed so **static pages and** `/api/bridge/*` **share the same origin** (required for `fetch("/api/bridge/...")` on `/pro/` and for the Mac app’s `bridgeAPIBaseURL`).

### CI (optional)

The workflow `.github/workflows/vercel-deploy.yml` deploys with **`vercel pull` → `vercel build` → `vercel deploy --prebuilt`** ([Vercel CI pattern](https://vercel.com/docs/deployments/git/vercel-for-github)). Add repository secrets **`VERCEL_TOKEN`**, **`VERCEL_ORG_ID`**, and **`VERCEL_PROJECT_ID`**. If you use only Vercel’s Git integration, you can skip this workflow and rely on automatic deployments.

### Local CLI

```bash
vercel login
vercel link
vercel env add QUICKPREVIEW_BRIDGE_SECRET production
vercel env add QUICKPREVIEW_SITE_URL production
vercel deploy --prod
```

## Finder Selection Follow

Finder selection follow is available in the `Pro` build configuration. Once a video is loaded, selecting a different video in Finder automatically switches playback to that selected file while the mirrored PRO entitlement remains active.

The background shortcut is still optional in both editions. In the App Store edition it reopens the player; in the PRO edition it can also continue the Finder-driven flow.

## Build Notes

1. Open `QuickPreview.xcodeproj` in Xcode.
2. Set your Team and bundle identifier for `QuickPreview`.
3. Use `./Scripts/build.sh` for the guided build menu.
4. Use `Debug` or `Pro` when you need the direct-distribution behavior.
5. Use `Release` when you are preparing the Mac App Store edition.

## Build Script

Run the interactive menu:

- `./Scripts/build.sh`

You can also call the exact tasks directly:

- `./Scripts/build.sh debug`
- `./Scripts/build.sh appstore`
- `./Scripts/build.sh pro`
- `./Scripts/build.sh archive-appstore`
- `./Scripts/build.sh archive-pro`
- `./Scripts/build.sh package-pro`
- `./Scripts/build.sh show-settings Release`
- `./Scripts/build.sh show-settings Pro`
- `./Scripts/build.sh clean`

Notes:

- `archive-appstore` now writes the archive into Xcode's standard archives folder so it appears in Organizer.
- `archive-pro` stays in the repo-local `build/archives/` folder because it is for direct-distribution validation, not App Store submission.

## Important Environment Requirement

`xcodebuild` and `swift` are blocked on this machine until the Xcode license is accepted:

- Run: `sudo xcodebuild -license`

After accepting the license, build and manual runtime verification can proceed.
