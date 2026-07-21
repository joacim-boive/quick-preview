import XCTest
@testable import QuickPreview

final class MediaLocationStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: MediaLocationStore!

    private let videoA = URL(fileURLWithPath: "/tmp/quickpreview-tests/location-a.mp4")
    private let videoB = URL(fileURLWithPath: "/tmp/quickpreview-tests/location-b.mp4")

    override func setUp() {
        super.setUp()
        let suite = TestUserDefaults.makeSuite()
        suiteName = suite.suiteName
        defaults = suite.defaults
        store = MediaLocationStore(defaults: defaults, persistDebounceInterval: 0)
    }

    override func tearDown() {
        store.flushPendingWrites()
        TestUserDefaults.tearDown(suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUpsertCoordinatesPersistsAndReloads() {
        _ = store.upsertCoordinates(for: videoA, latitude: 59.3293, longitude: 18.0686)
        store.flushPendingWrites()

        let reloaded = MediaLocationStore(defaults: defaults, persistDebounceInterval: 0)
        let record = reloaded.location(for: videoA)
        XCTAssertEqual(record?.latitude, 59.3293)
        XCTAssertEqual(record?.longitude, 18.0686)
        XCTAssertEqual(record?.status, .pending)
    }

    func testStatusTransitionsAndDisplayPlaceName() {
        XCTAssertEqual(store.displayPlaceName(forPath: videoA.path), "—")

        _ = store.upsertCoordinates(for: videoA, latitude: 1, longitude: 2)
        XCTAssertEqual(store.displayPlaceName(forPath: videoA.path), "")

        _ = store.markResolving(for: videoA)
        XCTAssertEqual(store.location(for: videoA)?.status, .resolving)
        XCTAssertEqual(store.displayPlaceName(forPath: videoA.path), "")

        _ = store.setPlaceName(for: videoA, placeName: " Stockholm ")
        XCTAssertEqual(store.location(for: videoA)?.status, .resolved)
        XCTAssertEqual(store.location(for: videoA)?.placeName, "Stockholm")
        XCTAssertEqual(store.displayPlaceName(forPath: videoA.path), "Stockholm")

        _ = store.markUnavailable(for: videoB)
        XCTAssertEqual(store.location(for: videoB)?.status, .unavailable)
        XCTAssertEqual(store.displayPlaceName(forPath: videoB.path), "—")
    }

    func testPathsNeedingResolution() {
        _ = store.upsertCoordinates(for: videoA, latitude: 1, longitude: 2)
        _ = store.markUnavailable(for: videoB)

        let needing = store.pathsNeedingResolution(from: [
            videoA.path,
            videoB.path,
            "/tmp/quickpreview-tests/location-c.mp4"
        ])
        XCTAssertEqual(
            Set(needing),
            Set([
                videoA.quickPreviewNormalizedPath,
                URL(fileURLWithPath: "/tmp/quickpreview-tests/location-c.mp4").quickPreviewNormalizedPath
            ])
        )
    }

    func testMarkFailedKeepsCoordinates() {
        _ = store.upsertCoordinates(for: videoA, latitude: 10, longitude: 20)
        _ = store.markFailed(for: videoA)
        let record = store.location(for: videoA)
        XCTAssertEqual(record?.status, .failed)
        XCTAssertEqual(record?.latitude, 10)
        XCTAssertEqual(record?.longitude, 20)
        XCTAssertTrue(store.pathsNeedingResolution(from: [videoA.path]).contains(videoA.quickPreviewNormalizedPath))
    }

    func testSortedByPlaceNamePutsNamedLocationsFirstAlphabetically() {
        let bookmarkStore = BookmarkStore(defaults: defaults, persistDebounceInterval: 0)
        let stockholm = bookmarkStore.addBookmark(videoURL: videoA, timeSeconds: 1)
        let berlin = bookmarkStore.addBookmark(videoURL: videoB, timeSeconds: 1)
        let unknown = bookmarkStore.addBookmark(
            videoURL: URL(fileURLWithPath: "/tmp/quickpreview-tests/location-c.mp4"),
            timeSeconds: 1
        )

        _ = store.upsertCoordinates(for: videoA, latitude: 59.3, longitude: 18.0)
        _ = store.setPlaceName(for: videoA, placeName: "Stockholm")
        _ = store.upsertCoordinates(for: videoB, latitude: 52.5, longitude: 13.4)
        _ = store.setPlaceName(for: videoB, placeName: "Berlin")
        _ = store.markUnavailable(for: URL(fileURLWithPath: "/tmp/quickpreview-tests/location-c.mp4"))

        let ascending = store.sortedByPlaceName([stockholm, berlin, unknown], ascending: true)
        XCTAssertEqual(ascending.map(\.id), [berlin.id, stockholm.id, unknown.id])

        let descending = store.sortedByPlaceName([stockholm, berlin, unknown], ascending: false)
        XCTAssertEqual(descending.map(\.id), [stockholm.id, berlin.id, unknown.id])
    }
}

final class MediaLocationExtractorTests: XCTestCase {
    func testParseISO6709WithAltitudeAndSigns() {
        let coordinates = MediaLocationExtractor.parseISO6709("+39.9410-075.2040+007.371/")
        XCTAssertEqual(coordinates?.latitude ?? 0, 39.9410, accuracy: 0.0001)
        XCTAssertEqual(coordinates?.longitude ?? 0, -75.2040, accuracy: 0.0001)
    }

    func testParseISO6709Stockholm() {
        let coordinates = MediaLocationExtractor.parseISO6709("+59.3293+018.0686/")
        XCTAssertEqual(coordinates?.latitude ?? 0, 59.3293, accuracy: 0.0001)
        XCTAssertEqual(coordinates?.longitude ?? 0, 18.0686, accuracy: 0.0001)
    }

    func testParseISO6709RejectsInvalid() {
        XCTAssertNil(MediaLocationExtractor.parseISO6709(""))
        XCTAssertNil(MediaLocationExtractor.parseISO6709("not-a-location"))
        XCTAssertNil(MediaLocationExtractor.parseISO6709("+99.0000+018.0000/"))
    }
}

final class MediaLocationPlaceNameTests: XCTestCase {
    func testPreferredNameOrder() {
        XCTAssertEqual(
            MediaLocationPlaceName.preferredName(
                locality: "Stockholm",
                subAdministrativeArea: "County",
                name: "Somewhere",
                administrativeArea: "AB"
            ),
            "Stockholm"
        )
        XCTAssertEqual(
            MediaLocationPlaceName.preferredName(
                locality: nil,
                subAdministrativeArea: " County ",
                name: "Somewhere",
                administrativeArea: "AB"
            ),
            "County"
        )
        XCTAssertEqual(
            MediaLocationPlaceName.preferredName(
                locality: "  ",
                subAdministrativeArea: nil,
                name: "Central Park",
                administrativeArea: "NY"
            ),
            "Central Park"
        )
        XCTAssertNil(
            MediaLocationPlaceName.preferredName(
                locality: nil,
                subAdministrativeArea: " ",
                name: nil,
                administrativeArea: nil
            )
        )
    }
}

final class BookmarkBestForOpeningTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: BookmarkStore!

    private let videoA = URL(fileURLWithPath: "/tmp/quickpreview-tests/best-open-a.mp4")

    override func setUp() {
        super.setUp()
        let suite = TestUserDefaults.makeSuite()
        suiteName = suite.suiteName
        defaults = suite.defaults
        store = BookmarkStore(defaults: defaults, persistDebounceInterval: 0)
    }

    override func tearDown() {
        store.flushPendingWrites()
        TestUserDefaults.tearDown(suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPrefersImportedBookmarkForPath() {
        let imported = store.addImportedBookmarks(videoURLs: [videoA]).first
        XCTAssertNotNil(imported)
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 12)

        let best = store.bestBookmarkForOpening(videoPath: videoA.path)
        XCTAssertEqual(best?.id, imported?.id)
        XCTAssertEqual(best?.isImported, true)
    }

    func testFallsBackToEarliestBookmarkWhenNoImport() {
        let first = store.addBookmark(videoURL: videoA, timeSeconds: 5)
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 12)
        let best = store.bestBookmarkForOpening(videoPath: videoA.path)
        XCTAssertEqual(best?.id, first.id)
    }
}
