# DaVinci Resolve FCPXML export

**Date:** 2026-07-21  
**Status:** Validated design  
**Approach:** Dedicated FCPXML exporter (ResolveExportBuilder + FCPXMLExporter)

## Goal

Let users select reviewed clips in QuickPreview and export them as an FCPXML that DaVinci Resolve can import as a new timeline: in/out ranges as clips, bookmarks as markers, tags as metadata.

## Decisions

| Topic                           | Choice                                                          |
| ------------------------------- | --------------------------------------------------------------- |
| Clip content                    | Ranges as timeline clips **and** bookmarks as markers           |
| Settings in export              | Core paths/in-out + tags as metadata (no volume/rotation in v1) |
| Entry points                    | Bookmarks manager batch **and** player “export this clip”       |
| Format                          | FCPXML only (no EDL in v1)                                      |
| Missing in/out                  | Use full media duration                                         |
| Same source, multiple bookmarks | One timeline clip per unique file; merge markers/tags           |

## Export model

Each timeline item is one source file:

- `videoPath`
- `clipStart` / `clipEnd` — saved clip selection, else `0…duration`
- `markers` — bookmarks on that file (source times), preferably within the exported range
- `tags` — union of tags from selected bookmarks for that file
- Frame rate and duration from media when readable

**Batch (bookmarks manager):** unique files from multi-select, ordered by first selection appearance.  
**Player:** current file only; current selection or full duration.

## Architecture

```
UI (Bookmarks / Player)
  → ResolveExportBuilder  (selections + bookmarks → [ResolveExportItem])
  → FCPXMLExporter        (items → .fcpxml)
  → NSSavePanel
```

### New types / modules

- `ResolveExportItem` — path, start/end, markers, tags, frame rate, duration
- `ResolveExportBuilder` — dedupe by path; read clip selection from the same UserDefaults store the player uses (`clipSelectionByPath`); fill missing in/out with media duration; attach in-range bookmarks
- `FCPXMLExporter` — write Resolve-importable FCPXML with a sequential timeline
- UI actions: **Export to Resolve…** on bookmarks toolbar/context menu (enabled when selection is non-empty) and on the player (File / clip menu)

### Data flow

1. Collect unique `videoPath`s (batch or current).
2. For each path: load selection → else full duration; collect bookmarks in range → markers; union tags.
3. Present save panel → write `Something.fcpxml`.
4. User imports in Resolve (Import Timeline / drag FCPXML) and relinks media if paths differ.

### Edge cases

- Unreadable media duration → skip that file; completion alert lists skips.
- Markers outside exported range → drop (do not clamp unless exactly on in/out).
- Sandbox: reuse existing security-scoped media access when reading duration/frame rate.

## FCPXML shape (v1)

- FCPXML in a Resolve-friendly form (target ~1.9-style structure).
- One project/sequence named from the save filename.
- One timeline clip per `ResolveExportItem`, back-to-back in selection order.
- Source in/out from `clipStart`/`clipEnd`; media via absolute `file://` URL.
- Bookmarks → markers at source time; marker name from primary tag or formatted timecode; remaining tags in marker notes.
- Clip name: filename stem + tags summary when tags exist (e.g. `clip_a [hero, keep]`).
- Frame rate from media when readable; fallback `25` with a note in the completion alert if any fallback was used.

## Out of scope (v1)

- Volume boost / rotation in interchange
- EDL (or dual-format save panel)
- Copying/relinking media into a Resolve project folder
- Multi-track timelines
- Custom timeline timecode start

## Test plan

Unit tests (no Resolve required):

- Builder: multiple bookmarks on the same file → one item, merged markers/tags
- Builder: no selection → full duration
- Builder: markers outside range are dropped
- Exporter: valid XML; correct in/out, marker times, `file://` paths
- Exporter: empty input → clear error, no file written

## Manual verification

1. Select several bookmarks across files with saved in/outs → export → import FCPXML in Resolve → confirm clip lengths and marker times.
2. Select bookmarks for a file with no in/out → confirm full-duration clip.
3. Export current player selection → confirm single-clip timeline.
4. Confirm tags appear in clip naming / marker notes as designed.
