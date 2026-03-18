# V1 Validation Notes

## What Was Verified

- Project structure and target separation were created:
  - App target source files
  - Quick Look extension source files
  - Shared playback module
- Shared playback logic includes:
  - Full-loop mode
  - Range-loop primitives for future A-B loop support
  - Fine/coarse seek and frame-step behavior
- No editor diagnostics reported for `Sources` and project file via IDE lint scan.

## Build Verification Results

The project now builds successfully with Xcode CLI:

- `xcodebuild -list -project "QuickPreview.xcodeproj"` succeeds and shows both targets/schemes.
- `xcodebuild -project "QuickPreview.xcodeproj" -scheme "QuickPreview" ... build` succeeds.
- `xcodebuild -project "QuickPreview.xcodeproj" -scheme "QuickPreviewExtension" ... build` succeeds.

Built artifacts were produced at:

- `build/Build/Products/Debug/QuickPreview.app`
- `build/Build/Products/Debug/QuickPreviewExtension.appex`

One packaging issue was found and fixed during validation:

- The extension bundle identifier must be prefixed by the parent app bundle identifier.
- Updated extension identifier to `com.quickpreview.app.extension`.

## Manual Runtime Validation Checklist

1. Build and run `QuickPreview` app target.
2. Open sample files in standalone app:
   - MP4, MOV, M4V
   - short and long files
   - different frame rates
3. Verify controls:
   - Space (play/pause)
   - L (loop on/off)
   - Arrow keys fine/coarse seek
   - Up/Down frame-step
   - Slider precision and smooth playback after repeated seeks
4. Test extension in Finder Quick Look:
   - Trigger preview with Space
   - Confirm loop toggle and precise navigation behavior
5. Validate extension fallback:
   - Open In App handoff loads the same file in standalone player.

## Known Constraints

- Quick Look extension interaction behavior can vary by macOS security/signing context.
- In debug/unsigned builds, extension discovery can be inconsistent (`pluginkit` may not list the extension even when the app embeds it).
- For standard video UTIs (for example MP4/MOV), macOS may continue to use the system preview pipeline, so custom extension UI might not appear for every Finder preview scenario.
- Global hotkey uses `Ctrl+Space` in fallback app; users may need to adjust if this conflicts with system input-source shortcuts.
