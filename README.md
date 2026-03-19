# Quick Preview Video Loop

macOS video preview project that prioritizes Finder Quick Look behavior and adds:

- Full-file loop toggle
- Precise seek controls (fine/coarse and frame-step)
- High-resolution scrubber
- Standalone fallback player app

## Project Layout

- `QuickPreview.xcodeproj`: Xcode project with app and Quick Look extension targets.
- `Sources/Shared`: Shared playback engine and loop/seek logic.
- `Sources/QuickLookExtension`: Quick Look preview controller.
- `Sources/App`: Standalone fallback app and hotkey manager.
- `Sources/Resources`: Info.plist files for both targets.

## Controls

- `Space`: Play/pause
- `L`: Toggle full-video looping
- `Left/Right`: Fine seek (`0.1s`)
- `Shift+Left/Shift+Right`: Coarse seek (`1.0s`)
- `Up/Down`: Frame step (+/- one frame, with fine-step fallback)
- `Set Start` / `Set End`: Mark replay selection points
- `Replay Selection`: Loop only the marked segment
- `Clear Selection`: Remove current replay segment

## Finder-First Behavior

The extension target (`QuickPreviewExtension`) is designed for Finder Quick Look previews, and includes loop + precise navigation controls in its UI.

If extension constraints prevent expected interaction in a given context, the preview offers **Open In App** to hand off to the standalone player.

## Finder Selection Follow

In the standalone app, once a video is loaded, selecting a different video in Finder automatically switches playback to that selected file.

The global shortcut is still available, but no longer required to switch to another Finder-selected video while the player is active.

## Build Notes

1. Open `QuickPreview.xcodeproj` in Xcode.
2. Set your Team and bundle identifiers for:
   - `QuickPreview`
   - `QuickPreviewExtension`
3. Build and run the app target.
4. Enable/sign the Quick Look extension as needed for your macOS environment.

## Important Environment Requirement

`xcodebuild` and `swift` are blocked on this machine until the Xcode license is accepted:

- Run: `sudo xcodebuild -license`

After accepting the license, build and manual runtime verification can proceed.
