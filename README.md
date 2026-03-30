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
- `Up/Down`: Move through bookmarks while the bookmark manager is open
- `Shift+Up/Down`: Frame step (+/- one frame, with fine-step fallback)
- `Set Start` / `Set End`: Mark replay selection points
- `Replay Selection`: Loop only the marked segment
- `Clear Selection`: Remove current replay segment

## Finder Selection Follow

In the standalone app, once a video is loaded, selecting a different video in Finder automatically switches playback to that selected file.

The global shortcut is still available, but no longer required to switch to another Finder-selected video while the player is active.

## Build Notes

1. Open `QuickPreview.xcodeproj` in Xcode.
2. Set your Team and bundle identifier for `QuickPreview`.
3. Build and run the app target.

## Important Environment Requirement

`xcodebuild` and `swift` are blocked on this machine until the Xcode license is accepted:

- Run: `sudo xcodebuild -license`

After accepting the license, build and manual runtime verification can proceed.
