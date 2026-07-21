import Foundation
import XCTest
@testable import QuickPreview

private struct StubMediaTimingProvider: MediaTimingProviding {
    var timingsByPath: [String: MediaTiming]
    var missingPaths: Set<String> = []

    func timing(for url: URL) async -> MediaTiming? {
        let path = url.quickPreviewNormalizedPath
        if missingPaths.contains(path) {
            return nil
        }
        return timingsByPath[path] ?? timingsByPath[url.path]
    }
}

final class ResolveExportBuilderTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = TestUserDefaults.makeSuite(named: "ResolveExportBuilderTests")
        suiteName = suite.suiteName
        defaults = suite.defaults
    }

    override func tearDown() {
        TestUserDefaults.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMergesBookmarksOnSameFileIntoOneItem() async {
        let path = "/tmp/clip_a.mp4"
        let timing = MediaTiming(
            durationSeconds: 20,
            frameRate: 25,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: false
        )
        let provider = StubMediaTimingProvider(timingsByPath: [path: timing])
        let bookmarks = [
            makeBookmark(path: path, time: 2, tags: ["hero"]),
            makeBookmark(path: path, time: 5, tags: ["keep", "hero"])
        ]

        let result = await ResolveExportBuilder.build(
            selectedBookmarks: bookmarks,
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].clipStart, 0)
        XCTAssertEqual(result.items[0].clipEnd, 20)
        XCTAssertEqual(result.items[0].tags, ["hero", "keep"])
        XCTAssertEqual(result.items[0].markers.count, 2)
        XCTAssertEqual(result.items[0].markers[0].name, "hero")
        XCTAssertEqual(result.items[0].markers[1].name, "keep")
        XCTAssertEqual(result.items[0].markers[1].note, "hero")
    }

    func testUsesStoredSelectionWhenPresent() async {
        let path = "/tmp/clip_b.mp4"
        let timing = MediaTiming(
            durationSeconds: 30,
            frameRate: 24,
            width: 1280,
            height: 720,
            usedFallbackFrameRate: false
        )
        let provider = StubMediaTimingProvider(timingsByPath: [path: timing])
        let selection = PersistedClipSelection(start: 3, end: 10)
        let encoded = try! JSONEncoder().encode([path: selection])
        defaults.set(encoded, forKey: ClipSelectionStore.defaultsKey)

        let result = await ResolveExportBuilder.build(
            selectedBookmarks: [makeBookmark(path: path, time: 4, tags: [])],
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].clipStart, 3)
        XCTAssertEqual(result.items[0].clipEnd, 10)
    }

    func testDropsMarkersOutsideExportedRange() async {
        let path = "/tmp/clip_c.mp4"
        let timing = MediaTiming(
            durationSeconds: 40,
            frameRate: 25,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: false
        )
        let provider = StubMediaTimingProvider(timingsByPath: [path: timing])
        let selection = PersistedClipSelection(start: 5, end: 15)
        defaults.set(try! JSONEncoder().encode([path: selection]), forKey: ClipSelectionStore.defaultsKey)

        let bookmarks = [
            makeBookmark(path: path, time: 4, tags: ["before"]),
            makeBookmark(path: path, time: 8, tags: ["inside"]),
            makeBookmark(path: path, time: 16, tags: ["after"])
        ]

        let result = await ResolveExportBuilder.build(
            selectedBookmarks: bookmarks,
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].markers.map(\.name), ["inside"])
    }

    func testSkipsUnreadableMedia() async {
        let path = "/tmp/missing.mp4"
        let provider = StubMediaTimingProvider(timingsByPath: [:], missingPaths: [path])

        let result = await ResolveExportBuilder.build(
            selectedBookmarks: [makeBookmark(path: path, time: 1, tags: [])],
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skippedPaths, [path])
    }

    func testPlayerOverrideUsesExplicitRange() async {
        let path = "/tmp/clip_d.mp4"
        let timing = MediaTiming(
            durationSeconds: 12,
            frameRate: 25,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: false
        )
        let provider = StubMediaTimingProvider(timingsByPath: [path: timing])

        let result = await ResolveExportBuilder.build(
            videoPath: path,
            clipStart: 1,
            clipEnd: 4,
            bookmarks: [makeBookmark(path: path, time: 2, tags: ["mark"])],
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].clipStart, 1)
        XCTAssertEqual(result.items[0].clipEnd, 4)
        XCTAssertEqual(result.items[0].markers.count, 1)
    }

    func testUntaggedMarkerUsesMediaFrameRateForTimecode() async {
        let path = "/tmp/clip_e.mp4"
        let timing = MediaTiming(
            durationSeconds: 10,
            frameRate: 24,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: false
        )
        let provider = StubMediaTimingProvider(timingsByPath: [path: timing])

        let result = await ResolveExportBuilder.build(
            selectedBookmarks: [makeBookmark(path: path, time: 1.5, tags: [])],
            defaults: defaults,
            timingProvider: provider
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].markers.count, 1)
        // 1.5s at 24fps → 01:00:12 (mm:ss:ff with 12 frames)
        XCTAssertEqual(result.items[0].markers[0].name, "00:01:12")
    }

    func testFormatTimecodeUsesProvidedFrameRate() {
        XCTAssertEqual(ResolveExportBuilder.formatTimecode(1.5, frameRate: 24), "00:01:12")
        XCTAssertEqual(ResolveExportBuilder.formatTimecode(1.5, frameRate: 25), "00:01:12")
        XCTAssertEqual(ResolveExportBuilder.formatTimecode(1.04, frameRate: 25), "00:01:01")
        XCTAssertEqual(ResolveExportBuilder.formatTimecode(1.04, frameRate: 24), "00:01:00")
    }

    private func makeBookmark(path: String, time: PlaybackSeconds, tags: [String]) -> Bookmark {
        Bookmark(
            id: BookmarkID(),
            videoPath: path,
            timeSeconds: time,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            tags: tags
        )
    }
}

final class FCPXMLExporterTests: XCTestCase {
    func testExportsValidXMLWithMarkersAndPaths() throws {
        let item = ResolveExportItem(
            videoPath: "/Movies/clip a.mp4",
            clipStart: 2,
            clipEnd: 7,
            durationSeconds: 20,
            frameRate: 25,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: false,
            tags: ["hero", "keep"],
            markers: [
                ResolveExportMarker(timeSeconds: 3.5, name: "hero", note: "keep")
            ]
        )

        let xml = try FCPXMLExporter.exportXML(items: [item], projectName: "My Export")

        XCTAssertTrue(xml.contains("<fcpxml version=\"1.9\">"))
        XCTAssertTrue(xml.contains("project name=\"My Export\""))
        XCTAssertTrue(xml.contains("file:///Movies/clip%20a.mp4"))
        XCTAssertTrue(xml.contains("start=\"2s\""))
        XCTAssertTrue(xml.contains("duration=\"5s\""))
        XCTAssertTrue(xml.contains("value=\"hero\""))
        XCTAssertTrue(xml.contains("note=\"keep\""))
        XCTAssertTrue(xml.contains("name=\"clip a [hero, keep]\""))
    }

    func testMixedFrameRatesEmitSeparateFormats() throws {
        let items = [
            ResolveExportItem(
                videoPath: "/tmp/a.mp4",
                clipStart: 0,
                clipEnd: 2,
                durationSeconds: 10,
                frameRate: 24,
                width: 1280,
                height: 720,
                usedFallbackFrameRate: false,
                tags: [],
                markers: []
            ),
            ResolveExportItem(
                videoPath: "/tmp/b.mp4",
                clipStart: 0,
                clipEnd: 3,
                durationSeconds: 12,
                frameRate: 30,
                width: 1920,
                height: 1080,
                usedFallbackFrameRate: false,
                tags: [],
                markers: []
            )
        ]

        let xml = try FCPXMLExporter.exportXML(items: items, projectName: "Mixed")

        XCTAssertTrue(xml.contains("FFVideoFormat720p24"))
        XCTAssertTrue(xml.contains("FFVideoFormat1080p30"))
        XCTAssertTrue(xml.contains("frameDuration=\"1/24s\""))
        XCTAssertTrue(xml.contains("frameDuration=\"1/30s\""))
        XCTAssertTrue(xml.contains("format=\"r1\""))
        XCTAssertTrue(xml.contains("format=\"r2\""))
        XCTAssertTrue(xml.contains("<sequence format=\"r1\""))
    }

    func testEmptyItemsThrow() {
        XCTAssertThrowsError(try FCPXMLExporter.exportXML(items: [], projectName: "Empty")) { error in
            XCTAssertEqual(error as? ResolveExportError, .noExportableClips)
        }
    }

    func testWriteCreatesFile() throws {
        let item = ResolveExportItem(
            videoPath: "/tmp/out.mp4",
            clipStart: 0,
            clipEnd: 1,
            durationSeconds: 1,
            frameRate: 25,
            width: 1920,
            height: 1080,
            usedFallbackFrameRate: true,
            tags: [],
            markers: []
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickpreview-export-\(UUID().uuidString).fcpxml")
        defer { try? FileManager.default.removeItem(at: url) }

        try FCPXMLExporter.write(items: [item], projectName: "Temp", to: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("<fcpxml"))
    }
}
