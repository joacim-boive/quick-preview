import XCTest
@testable import QuickPreview

final class BookmarkStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: BookmarkStore!

    private let videoA = URL(fileURLWithPath: "/tmp/quickpreview-tests/a.mp4")
    private let videoB = URL(fileURLWithPath: "/tmp/quickpreview-tests/b.mp4")

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

    func testAddBookmarkPersistsAndReloads() {
        let bookmark = store.addBookmark(videoURL: videoA, timeSeconds: 12.5, tags: [" Cut ", "cut", "demo"])
        store.flushPendingWrites()

        XCTAssertEqual(bookmark.timeSeconds, 12.5)
        XCTAssertEqual(bookmark.tags, ["Cut", "demo"])
        XCTAssertFalse(bookmark.isProtected)

        let reloaded = BookmarkStore(defaults: defaults, persistDebounceInterval: 0)
        let all = reloaded.allBookmarks(visibility: .all)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, bookmark.id)
        XCTAssertEqual(all.first?.tags, ["Cut", "demo"])
    }

    func testUpdateTagsProtectionTimeAndThumbnail() {
        let bookmark = store.addBookmark(videoURL: videoA, timeSeconds: 5, tags: ["raw"])

        store.updateTags(for: bookmark.id, tags: ["final", "review"])
        store.updateProtection(for: bookmark.id, isProtected: true)
        store.updateThumbnailTimeSeconds(for: bookmark.id, thumbnailTimeSeconds: 3.25)
        store.updateTimeSeconds(for: bookmark.id, timeSeconds: 8.5)

        let updated = store.bookmark(for: bookmark.id)
        XCTAssertEqual(updated?.tags, ["final", "review"])
        XCTAssertEqual(updated?.isProtected, true)
        XCTAssertEqual(updated?.thumbnailTimeSeconds, 3.25)
        XCTAssertEqual(updated?.timeSeconds, 8.5)
        XCTAssertTrue(store.hasProtectedBookmarks())
        XCTAssertTrue(store.hasProtectedBookmarks(for: videoA))
        XCTAssertFalse(store.hasProtectedBookmarks(for: videoB))
    }

    func testUpdateTimeSecondsCanClearThumbnailWhenSynced() {
        let bookmark = store.addBookmark(videoURL: videoA, timeSeconds: 5)
        store.updateThumbnailTimeSeconds(for: bookmark.id, thumbnailTimeSeconds: 2)
        store.updateTimeSeconds(for: bookmark.id, timeSeconds: 9, syncThumbnailToBookmarkTime: true)

        XCTAssertEqual(store.bookmark(for: bookmark.id)?.timeSeconds, 9)
        XCTAssertNil(store.bookmark(for: bookmark.id)?.thumbnailTimeSeconds)
    }

    func testVisibilityAndScopeFiltering() {
        let publicBookmark = store.addBookmark(videoURL: videoA, timeSeconds: 1, tags: ["public"])
        let protectedBookmark = store.addBookmark(videoURL: videoA, timeSeconds: 2, tags: ["secret"])
        store.updateProtection(for: protectedBookmark.id, isProtected: true)
        _ = store.addBookmark(videoURL: videoB, timeSeconds: 3, tags: ["other"])

        let publicOnly = store.bookmarks(
            scope: .currentVideo,
            currentVideoURL: videoA,
            searchQuery: "",
            visibility: .publicOnly
        )
        XCTAssertEqual(publicOnly.map(\.id), [publicBookmark.id])

        let protectedOnly = store.bookmarks(
            scope: .protected,
            currentVideoURL: nil,
            searchQuery: "",
            visibility: .protectedOnly
        )
        XCTAssertEqual(protectedOnly.map(\.id), [protectedBookmark.id])

        let allForVideoA = store.bookmarks(
            scope: .currentVideo,
            currentVideoURL: videoA,
            searchQuery: "",
            visibility: .all
        )
        XCTAssertEqual(Set(allForVideoA.map(\.id)), [publicBookmark.id, protectedBookmark.id])
    }

    func testSearchAndSelectedTagMatching() {
        let keep = store.addBookmark(videoURL: videoA, timeSeconds: 70, tags: ["Action", "Cut"])
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 10, tags: ["Broll"])

        let byTag = store.bookmarksMatchingSelectedTags(
            ["action"],
            scope: .allVideos,
            currentVideoURL: nil,
            searchQuery: "",
            visibility: .all
        )
        XCTAssertEqual(byTag.map(\.id), [keep.id])

        let bySearch = store.bookmarks(
            scope: .allVideos,
            currentVideoURL: nil,
            searchQuery: "01:10 action",
            visibility: .all
        )
        XCTAssertEqual(bySearch.map(\.id), [keep.id])
    }

    func testTagCountsPreferHigherFrequencyAndIgnoreCase() {
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 1, tags: ["Cut"])
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 2, tags: ["cut", "demo"])
        _ = store.addBookmark(videoURL: videoB, timeSeconds: 3, tags: ["Demo"])

        let counts = store.tagCounts(
            selectedTags: [],
            scope: .allVideos,
            currentVideoURL: nil,
            searchQuery: "",
            visibility: .all
        )

        XCTAssertEqual(counts.map(\.tag), ["Cut", "demo"])
        XCTAssertEqual(counts.map(\.count), [2, 2])
    }

    func testBookmarkNearPositionFindsClosestWithinTolerance() {
        let near = store.addBookmark(videoURL: videoA, timeSeconds: 10.02)
        _ = store.addBookmark(videoURL: videoA, timeSeconds: 10.2)

        let match = store.bookmarkNearPosition(videoURL: videoA, timeSeconds: 10.0, tolerance: 0.05)
        XCTAssertEqual(match?.id, near.id)
        XCTAssertNil(store.bookmarkNearPosition(videoURL: videoA, timeSeconds: 11.0, tolerance: 0.05))
    }

    func testImportedMediaPlanAndReplaceDuplicate() {
        let existing = store.addBookmark(videoURL: videoA, timeSeconds: 4, tags: ["keep"])
        let plan = store.prepareImportedMediaImport(videoURLs: [videoA, videoB, videoB])

        XCTAssertEqual(plan.newMedia, [videoB])
        XCTAssertEqual(plan.duplicates.count, 1)
        XCTAssertEqual(plan.duplicates.first?.existingBookmarkID, existing.id)

        let skipped = store.applyImportedMediaImport(
            plan: plan,
            duplicateResolutionsByVideoPath: [videoA.path: .skip]
        )
        XCTAssertEqual(skipped.affectedBookmarkIDs.count, 1)
        XCTAssertEqual(store.bookmark(for: existing.id)?.isImported, false)
        XCTAssertEqual(
            store.bookmarks(scope: .imported, currentVideoURL: nil, searchQuery: "", visibility: .all).count,
            1
        )

        let replacePlan = store.prepareImportedMediaImport(videoURLs: [videoA])
        let replaced = store.applyImportedMediaImport(
            plan: replacePlan,
            duplicateResolutionsByVideoPath: [videoA.path: .replace]
        )
        XCTAssertTrue(replaced.affectedBookmarkIDs.contains(existing.id))
        XCTAssertEqual(store.bookmark(for: existing.id)?.isImported, true)
        XCTAssertTrue(store.bookmark(for: existing.id)?.tags.contains("imported") == true)
        XCTAssertEqual(
            store.bookmarks(scope: .imported, currentVideoURL: nil, searchQuery: "", visibility: .all).count,
            2
        )
    }

    func testRemoveBookmarksAndChangeNotification() {
        let first = store.addBookmark(videoURL: videoA, timeSeconds: 1)
        let second = store.addBookmark(videoURL: videoB, timeSeconds: 2)

        let expectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        store.removeBookmarks(ids: [first.id, second.id])
        wait(for: [expectation], timeout: 1)

        XCTAssertTrue(store.allBookmarks(visibility: .all).isEmpty)
    }

    func testFormattedTimestampAndTagParsingHelpers() {
        XCTAssertEqual(BookmarkStore.formattedTimestamp(65), "01:05")
        XCTAssertEqual(BookmarkStore.formattedTimestamp(3661), "01:01:01")
        XCTAssertEqual(BookmarkStore.formattedTimestamp(-1), "00:00")
        XCTAssertEqual(BookmarkStore.tags(from: " Alpha, beta ,ALPHA "), ["Alpha", "beta"])
        XCTAssertEqual(BookmarkStore.tagString(from: [" Alpha ", "beta", "alpha"]), "Alpha, beta")
        XCTAssertEqual(BookmarkStore.tagsByAdding(["cut", "Demo"], to: ["Cut", "raw"]), ["Cut", "raw", "Demo"])
        XCTAssertEqual(BookmarkStore.tagsByRemoving(["CUT", "missing"], from: ["Cut", "raw"]), ["raw"])
        XCTAssertEqual(BookmarkStore.tagsByRemoving([], from: ["Cut"]), ["Cut"])
    }

    func testAddTagsMergesWithoutDuplicatesAcrossBookmarks() {
        let first = store.addBookmark(videoURL: videoA, timeSeconds: 1, tags: ["Cut", "raw"])
        let second = store.addBookmark(videoURL: videoB, timeSeconds: 2, tags: ["demo"])
        let untouched = store.addBookmark(videoURL: videoA, timeSeconds: 3, tags: ["solo"])

        let expectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        store.addTags(to: [first.id, second.id], tags: [" cut ", "Review", "demo"])
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(store.bookmark(for: first.id)?.tags, ["Cut", "raw", "Review", "demo"])
        XCTAssertEqual(store.bookmark(for: second.id)?.tags, ["demo", "cut", "Review"])
        XCTAssertEqual(store.bookmark(for: untouched.id)?.tags, ["solo"])
    }

    func testRemoveTagsIgnoresMissingAndPreservesOthers() {
        let first = store.addBookmark(videoURL: videoA, timeSeconds: 1, tags: ["Cut", "raw", "keep"])
        let second = store.addBookmark(videoURL: videoB, timeSeconds: 2, tags: ["demo"])
        let untouched = store.addBookmark(videoURL: videoA, timeSeconds: 3, tags: ["Cut", "solo"])

        let expectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        store.removeTags(from: [first.id, second.id], tags: ["CUT", "missing", "demo"])
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(store.bookmark(for: first.id)?.tags, ["raw", "keep"])
        XCTAssertEqual(store.bookmark(for: second.id)?.tags, [])
        XCTAssertEqual(store.bookmark(for: untouched.id)?.tags, ["Cut", "solo"])
    }

    func testBulkTagUpdatesAreNoOpsForEmptyTagsOrUnknownIDs() {
        let bookmark = store.addBookmark(videoURL: videoA, timeSeconds: 1, tags: ["Cut"])

        let emptyAddExpectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        emptyAddExpectation.isInverted = true
        store.addTags(to: [bookmark.id], tags: [" ", ""])
        wait(for: [emptyAddExpectation], timeout: 0.2)

        let emptyRemoveExpectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        emptyRemoveExpectation.isInverted = true
        store.removeTags(from: [bookmark.id], tags: [])
        wait(for: [emptyRemoveExpectation], timeout: 0.2)

        let unknownIDExpectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        unknownIDExpectation.isInverted = true
        store.addTags(to: [UUID()], tags: ["new"])
        store.removeTags(from: [UUID()], tags: ["Cut"])
        wait(for: [unknownIDExpectation], timeout: 0.2)

        let duplicateAddExpectation = expectation(forNotification: .bookmarkStoreDidChange, object: store)
        duplicateAddExpectation.isInverted = true
        store.addTags(to: [bookmark.id], tags: ["cut"])
        wait(for: [duplicateAddExpectation], timeout: 0.2)

        XCTAssertEqual(store.bookmark(for: bookmark.id)?.tags, ["Cut"])
    }

    func testBookmarkValueHelpers() {
        let bookmark = Bookmark(
            id: UUID(),
            videoPath: "/Movies/clip.mp4",
            timeSeconds: 12,
            thumbnailTimeSeconds: nil,
            createdAt: Date(),
            updatedAt: Date(),
            tags: ["one"]
        )

        XCTAssertEqual(bookmark.videoDisplayName, "clip.mp4")
        XCTAssertEqual(bookmark.effectiveThumbnailTimeSeconds, 12)
        XCTAssertEqual(bookmark.withUpdatedTags(["two"]).tags, ["two"])
        XCTAssertTrue(bookmark.withUpdatedProtection(true).isProtected)
    }
}
