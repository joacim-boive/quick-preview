# Implementation plan: Resolve FCPXML export

1. Shared clip-selection reader (`ClipSelectionStore`) matching player UserDefaults key.
2. `MediaTimingProviding` + AVFoundation default (duration, frame rate, size).
3. `ResolveExportBuilder` — unique files, in/out or full duration, in-range markers, tags.
4. `FCPXMLExporter` — sequential spine, markers, tags in names/notes.
5. `ResolveExportCoordinator` — save panel + completion/skip alerts.
6. UI — bookmarks Export button + context menu; File → Export to Resolve… for player.
7. Unit tests for builder + exporter; wire files into Xcode project.
