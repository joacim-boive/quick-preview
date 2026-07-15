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
   - **`QUICKPREVIEW_SITE_URL`** — keep **`https://quickpreview.boive.se`** if that is where you host the static `site/` files. The API uses this for portal/support links, not as the protected download host.
   - **`QUICKPREVIEW_BRIDGE_PUBLIC_URL`** — your stable Vercel production origin, e.g. **`https://quick-preview-alpha.vercel.app`**, so the App Store app receives ticketed bridge URLs on the correct host.
   - **`QUICKPREVIEW_PRO_BLOB_PATHNAME`** — pathname of the **private Vercel Blob** that stores the notarized PRO DMG, e.g. **`downloads/QuickPreviewPro.dmg`**. The file is streamed only through **`/api/bridge/pro-download`** after ticket verification.
   - **`BLOB_READ_WRITE_TOKEN`** — Vercel Blob server token for the same project/environment.
   - **`QUICKPREVIEW_ALLOWED_ORIGINS`** — `https://quickpreview.boive.se` (comma-separated if you add more) so the browser can **POST** `create-link-code` from your static portal to Vercel (**CORS**).
   - **`QUICKPREVIEW_DEVELOPER_ID_APP`** — your **Developer ID Application** signing identity for direct distribution.
   - **Notarization credentials for `./Scripts/build.sh package-pro`** — either:
     - **`QUICKPREVIEW_NOTARY_PROFILE`** — keychain profile created with `xcrun notarytool store-credentials`
     - or **`QUICKPREVIEW_NOTARY_KEY`**, **`QUICKPREVIEW_NOTARY_KEY_ID`**, **`QUICKPREVIEW_NOTARY_ISSUER`**
     - or **`QUICKPREVIEW_NOTARY_APPLE_ID`**, **`QUICKPREVIEW_NOTARY_TEAM_ID`**, **`QUICKPREVIEW_NOTARY_PASSWORD`**
3. **Split hosting:** If the marketing site lives on `quickpreview.boive.se` and only **Vercel** runs **`/api/bridge/*`**, set **`bridgeAPIBaseURL`** in `AppEdition.swift` and the **`qp-bridge-api-origin`** meta tags on `site/pro/*.html` to your Vercel **Production** URL (see **Project → Domains**). Re-upload static files to `boive.se` after changing the meta tags.

### Same-origin note

You only need `quickpreview.boive.se` on Vercel if you want **one** host for both static files and API. If the site stays elsewhere, use the split setup above instead of moving DNS for the main domain to Vercel.

### HTTP 401 — “Authentication Required” (HTML from Vercel)

If **`debug.log`** shows **`Bridge HTTP 401`** and a large HTML body mentioning **Vercel authentication** or **deployment protection**, the **Mac app and browsers are not logged into Vercel**, so every request to that deployment is blocked before it reaches **`/api/bridge/*`**.

**Fix (dashboard):** [Project → Settings → Deployment Protection](https://vercel.com/docs/deployment-protection). For the environment you use in production (and for **Preview** if the app or portal hits preview URLs), either:

- Turn **off** protection for **Production** (typical for a public marketing site + API), or  
- Enable **“Only protect Preview Deployments”** (or equivalent) so **production** deployments stay **public**, or  
- Stop using a **password- / SSO-protected** `*.vercel.app` URL as **`bridgeAPIBaseURL`**; point the app at an **unprotected** production deployment or custom domain.

The subscriber bridge must be callable **without** a Vercel login cookie or bypass token. Do not rely on [protection bypass query parameters](https://vercel.com/docs/deployment-protection/methods-to-bypass-deployment-protection/protection-bypass-automation) for normal app traffic.

### CI (optional)

The workflow `.github/workflows/vercel-deploy.yml` deploys with **`vercel pull` → `vercel build` → `vercel deploy --prebuilt`** ([Vercel CI pattern](https://vercel.com/docs/deployments/git/vercel-for-github)). Add repository secrets **`VERCEL_TOKEN`**, **`VERCEL_ORG_ID`**, and **`VERCEL_PROJECT_ID`**. If you use only Vercel’s Git integration, you can skip this workflow and rely on automatic deployments.

### Local CLI

```bash
vercel login
vercel link
vercel env add QUICKPREVIEW_BRIDGE_SECRET production
vercel env add QUICKPREVIEW_SITE_URL production
vercel env add QUICKPREVIEW_BRIDGE_PUBLIC_URL production
vercel env add QUICKPREVIEW_PRO_BLOB_PATHNAME production
vercel deploy --prod
```

## Finder Selection Follow

Finder selection follow is available in the `Pro` build configuration. Once a video is loaded, selecting a different video in Finder automatically switches playback to that selected file while the mirrored PRO entitlement remains active.

The background shortcut is still optional in both editions. In the App Store edition it reopens the player; in the PRO edition it can also continue the Finder-driven flow.

## Build Notes

1. Open `QuickPreview.xcodeproj` in Xcode.
2. Set your Team and bundle identifier for `QuickPreview`.
3. Use `./Scripts/build.sh` for the guided build menu.
4. Use **`Debug`** when you need **QuickPreview PRO** (direct build, `quickpreview-pro://`, bundle `com.jboive.quickpreview.pro`). The default **QuickPreview** scheme runs this configuration.
5. Use **`Release`** for the **Mac App Store** app (`quickpreview://`, bundle `com.jboive.quickpreview`). Use the **QuickPreview App Store** shared scheme to **Run** this from Xcode with the debugger.
6. Use **`Pro`** (configuration) when you need an optimized direct-distribution PRO build. For a website-ready direct download, use **`./Scripts/build.sh package-pro`** to build, Developer ID sign, DMG, notarize, and staple the PRO app.
7. **Subscriber portal / `quickpreview://account-link`:** The website opens **`quickpreview://`**, which macOS delivers to whichever **QuickPreview** (App Store edition) owns that scheme—almost always the copy in **`/Applications`** from the App Store, **not** the **QuickPreview Pro** app from **`./Scripts/build.sh debug`**. To test linking against **your** build: run **`./Scripts/build.sh run-appstore`** (builds **Release** and opens **QuickPreview.app**), or use the **QuickPreview App Store** Xcode scheme—then quit or temporarily move the store-installed QuickPreview so the URL opens this build.
8. **Help → Open Debug Log…** appends bridge/deep-link diagnostics to **`~/Library/Application Support/QuickPreview/debug.log`** (same folder is revealed by **Show Debug Log in Finder**).

## Build Script

Run the interactive menu:

- `./Scripts/build.sh`

You can also call the exact tasks directly:

- `./Scripts/build.sh debug`
- `./Scripts/build.sh appstore`
- `./Scripts/build.sh run-appstore`
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
- `package-pro` now produces **`build/packages/QuickPreviewPro.dmg`** and requires Developer ID + notarization credentials in the environment.

## Important Environment Requirement

`xcodebuild` and `swift` are blocked on this machine until the Xcode license is accepted:

- Run: `sudo xcodebuild -license`

After accepting the license, build and manual runtime verification can proceed.
