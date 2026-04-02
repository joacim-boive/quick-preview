# V1 Validation Notes

## What Was Verified

- Project structure and target separation were created:
  - App target source files
  - Shared playback module
- Shared playback logic includes:
  - Full-loop mode
  - Range-loop primitives for future A-B loop support
  - Fine/coarse seek, bookmark navigation, and Shift+Up/Down frame-step behavior
- No editor diagnostics reported for `Sources` and project file via IDE lint scan.

## Build Verification Results

The project now builds successfully with Xcode CLI:

- `xcodebuild -list -project "QuickPreview.xcodeproj"` succeeds and shows the standalone app scheme.
- `xcodebuild -project "QuickPreview.xcodeproj" -scheme "QuickPreview" ... build` succeeds.

Built artifacts were produced at:

- `build/Build/Products/Debug/QuickPreview.app`

## Manual Runtime Validation Checklist

1. Build and run `QuickPreview` app target.
2. Open sample files in standalone app:
   - MP4, MOV, M4V
   - short and long files
   - different frame rates
3. Verify controls:
   - Space (play/pause)
   - L (loop on/off)
   - Left/Right and Shift+Left/Right seek behavior
   - Up/Down bookmark navigation with the bookmark manager open
   - Shift+Up/Down frame-step
   - Slider precision and smooth playback after repeated seeks

## Known Constraints

- Background shortcuts now require an explicit user choice; the helper no longer assumes `Ctrl+Space` by default.
