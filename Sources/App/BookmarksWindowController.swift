import AVFoundation
import AVKit
import Cocoa
import UniformTypeIdentifiers

final class BookmarksWindowController: NSWindowController, NSWindowDelegate {
    private static let reopenOnLaunchDefaultsKey = "reopenBookmarksWindowOnLaunch"
    private static let windowFrameDefaultsKey = "bookmarksWindowFrame"
    private static let viewStateDefaultsKey = "bookmarksWindowViewState"

    private enum DisplayMode: Int {
        case bookmarks
        case tagBrowser
    }

    private enum ColumnIdentifier {
        static let thumbnail = NSUserInterfaceItemIdentifier("thumbnail")
        static let time = NSUserInterfaceItemIdentifier("time")
        static let filename = NSUserInterfaceItemIdentifier("filename")
        static let importedDate = NSUserInterfaceItemIdentifier("importedDate")
        static let fileCreatedDate = NSUserInterfaceItemIdentifier("fileCreatedDate")
        static let protected = NSUserInterfaceItemIdentifier("protected")
        static let tags = NSUserInterfaceItemIdentifier("tags")
        static let actions = NSUserInterfaceItemIdentifier("actions")
        static let remove = NSUserInterfaceItemIdentifier("remove")
    }

    private enum SortDescriptorKey {
        static let importedAt = "importedAt"
        static let fileCreatedAt = "fileCreatedAt"
    }

    private enum ImportedMediaDuplicatePromptAction {
        case replace
        case replaceAll
        case skip
        case skipAll
        case cancel
    }

    private let bookmarkStore: BookmarkStore
    private let thumbnailService: VideoThumbnailService
    private let protectedBookmarksSessionController: ProtectedBookmarksSessionController
    private let searchField = NSSearchField(frame: .zero)
    private let scopeControl = NSSegmentedControl(labels: ["Current Video", "All Videos", "Imported"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Bookmarks", "Tags"], trackingMode: .selectOne, target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let contentStackView = NSStackView()
    private let tagSelectionRow = NSStackView()
    private let tagSelectionSummaryLabel = NSTextField(labelWithString: "")
    private let clearTagSelectionButton = NSButton(title: "Clear Selection", target: nil, action: nil)
    private let tagCloudContainerView = NSView(frame: .zero)
    private let tagCloudScrollView = NSScrollView(frame: .zero)
    private let tagCloudCollectionView: NSCollectionView = {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let collectionView = NSCollectionView(frame: .zero)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        return collectionView
    }()
    private let tagCloudEmptyStateLabel = NSTextField(labelWithString: "No tags available in the current scope.")
    private let matchingClipsCountLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = BookmarkTableView(frame: .zero)
    private let emptyStateLabel = NSTextField(labelWithString: "No bookmarks yet.")
    private var escMonitor: Any?
    private var bookmarkNavigationMonitor: Any?
    private var bookmarkChangeObserver: NSObjectProtocol?
    private var protectedSessionObserver: NSObjectProtocol?
    private var tagCloudHeightConstraint: NSLayoutConstraint?
    private var bookmarks: [Bookmark] = []
    private var tagCounts: [BookmarkTagCount] = []
    private var selectedTags: [String] = []
    private var currentVideoURL: URL?
    private var currentScope: BookmarkListScope = .currentVideo
    private var currentSort: BookmarkSort = .automatic
    private var currentDisplayMode: DisplayMode = .bookmarks
    private var suppressBookmarkOpenOnSelectionChange = false
    private weak var activePreviewThumbnailCell: BookmarkThumbnailCellView?
    private var activeThumbnailPickerSheetController: BookmarkThumbnailPickerSheetController?
    private var pendingRevealHighlightBookmarkID: BookmarkID?
    private var isPreparingForApplicationTermination = false

    private struct SavedWindowFrame: Codable {
        let originX: CGFloat
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat

        var rect: NSRect {
            NSRect(x: originX, y: originY, width: width, height: height)
        }
    }

    private struct SavedViewState: Codable {
        let scopeRawValue: Int
        let displayModeRawValue: Int
        let searchQuery: String
        let selectedTags: [String]
        let selectedBookmarkID: BookmarkID?
    }

    private static let importedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fileCreatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var onOpenBookmark: ((Bookmark) -> Void)?
    var onWindowClosed: (() -> Void)?
    var onEscapeKey: (() -> Void)?
    var onPlayPauseRequested: (() -> Void)?

    init(
        bookmarkStore: BookmarkStore,
        thumbnailService: VideoThumbnailService,
        protectedBookmarksSessionController: ProtectedBookmarksSessionController
    ) {
        self.bookmarkStore = bookmarkStore
        self.thumbnailService = thumbnailService
        self.protectedBookmarksSessionController = protectedBookmarksSessionController
        let rootView = BookmarkDropView(frame: NSRect(x: 0, y: 0, width: 1080, height: 560))
        let window = NSWindow(
            contentRect: rootView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookmarks"
        window.contentView = rootView
        window.minSize = NSSize(width: 660, height: 420)
        super.init(window: window)
        window.delegate = self
        restoreWindowFrameIfNeeded()
        configureUI(on: rootView)
        installObservers()
        installEscKeyMonitor()
        installBookmarkNavigationMonitor()
        if !restoreViewStateIfNeeded() {
            reloadBookmarks()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        if let bookmarkNavigationMonitor {
            NSEvent.removeMonitor(bookmarkNavigationMonitor)
        }
        if let bookmarkChangeObserver {
            NotificationCenter.default.removeObserver(bookmarkChangeObserver)
        }
        if let protectedSessionObserver {
            NotificationCenter.default.removeObserver(protectedSessionObserver)
        }
    }

    func setCurrentVideoURL(_ videoURL: URL?) {
        currentVideoURL = videoURL?.standardizedFileURL
        reloadBookmarks()
    }

    func revealBookmark(_ bookmark: Bookmark) {
        revealBookmark(bookmark, preferredScope: nil, highlight: false)
    }

    func navigateSelection(delta: Int) {
        guard
            delta != 0,
            !bookmarks.isEmpty,
            window?.isVisible == true
        else {
            return
        }

        let selectedRow = tableView.selectedRow
        let unclampedRow = selectedRow >= 0
            ? selectedRow + delta
            : (delta > 0 ? 0 : bookmarks.count - 1)
        let targetRow = min(max(unclampedRow, 0), bookmarks.count - 1)

        guard targetRow != selectedRow else {
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(targetRow)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        dismissVisiblePreviewPanels()
        window?.makeFirstResponder(nil)
        persistWindowFrameIfNeeded()
        persistViewStateIfNeeded()
        if !isPreparingForApplicationTermination {
            Self.storeShouldReopenOnLaunch(false)
        }
        onWindowClosed?()
    }

    func windowDidMove(_ notification: Notification) {
        _ = notification
        persistWindowFrameIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        _ = notification
        persistWindowFrameIfNeeded()
    }

    func showAndTrackWindow() {
        showWindow(nil)
        Self.storeShouldReopenOnLaunch(true)
    }

    func prepareForApplicationTermination() {
        isPreparingForApplicationTermination = true
        persistWindowFrameIfNeeded()
        persistViewStateIfNeeded()
        Self.storeShouldReopenOnLaunch(window?.isVisible == true)
    }

    static func shouldReopenOnLaunch(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: reopenOnLaunchDefaultsKey)
    }

    private static func storeShouldReopenOnLaunch(
        _ shouldReopen: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(shouldReopen, forKey: reopenOnLaunchDefaultsKey)
    }

    private func persistWindowFrameIfNeeded(defaults: UserDefaults = .standard) {
        guard let savedFrame = currentPersistableWindowFrame() else { return }
        guard let data = try? JSONEncoder().encode(savedFrame) else { return }
        defaults.set(data, forKey: Self.windowFrameDefaultsKey)
    }

    private func currentPersistableWindowFrame() -> SavedWindowFrame? {
        guard let window else { return nil }
        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return SavedWindowFrame(
            originX: frame.origin.x,
            originY: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    private func restoreWindowFrameIfNeeded(defaults: UserDefaults = .standard) {
        guard
            let window,
            let data = defaults.data(forKey: Self.windowFrameDefaultsKey),
            let savedFrame = try? JSONDecoder().decode(SavedWindowFrame.self, from: data)
        else {
            return
        }

        let minimumSize = window.minSize
        var frame = savedFrame.rect
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = max(frame.height, minimumSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let maxWidth = max(visibleFrame.width, minimumSize.width)
            let maxHeight = max(visibleFrame.height, minimumSize.height)
            frame.size.width = min(frame.width, maxWidth)
            frame.size.height = min(frame.height, maxHeight)
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        }

        window.setFrame(frame, display: false)
    }

    private func persistViewStateIfNeeded(defaults: UserDefaults = .standard) {
        let selectedBookmarkID: BookmarkID? = {
            guard tableView.selectedRowIndexes.count == 1,
                  let selectedRow = tableView.selectedRowIndexes.first,
                  selectedRow >= 0,
                  selectedRow < bookmarks.count else {
                return nil
            }
            return bookmarks[selectedRow].id
        }()
        let state = SavedViewState(
            scopeRawValue: currentScope.rawValue,
            displayModeRawValue: currentDisplayMode.rawValue,
            searchQuery: searchField.stringValue,
            selectedTags: selectedTags,
            selectedBookmarkID: selectedBookmarkID
        )
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: Self.viewStateDefaultsKey)
    }

    @discardableResult
    private func restoreViewStateIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard
            let data = defaults.data(forKey: Self.viewStateDefaultsKey),
            let state = try? JSONDecoder().decode(SavedViewState.self, from: data)
        else {
            return false
        }
        currentScope = BookmarkListScope(rawValue: state.scopeRawValue) ?? fallbackScopeForLockedSession()
        currentDisplayMode = DisplayMode(rawValue: state.displayModeRawValue) ?? .bookmarks
        selectedTags = state.selectedTags
        searchField.stringValue = state.searchQuery
        refreshScopeControl()
        refreshDisplayModeUI()
        modeControl.selectedSegment = currentDisplayMode.rawValue
        reloadBookmarks(selecting: state.selectedBookmarkID)
        return true
    }

    private func configureUI(on rootView: BookmarkDropView) {
        guard let contentView = window?.contentView else { return }

        let controlsRow = NSStackView()
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 12

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search tags, time, or filename"
        searchField.delegate = self

        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.target = self
        scopeControl.action = #selector(handleScopeChanged(_:))
        scopeControl.segmentStyle = .rounded
        refreshScopeControl()

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.target = self
        modeControl.action = #selector(handleDisplayModeChanged(_:))
        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = currentDisplayMode.rawValue

        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.target = self
        importButton.action = #selector(handleImportMedia(_:))
        importButton.bezelStyle = .rounded

        controlsRow.addArrangedSubview(searchField)
        controlsRow.addArrangedSubview(scopeControl)
        controlsRow.addArrangedSubview(modeControl)
        controlsRow.addArrangedSubview(importButton)

        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.orientation = .vertical
        contentStackView.alignment = .leading
        contentStackView.spacing = 12

        tagSelectionRow.translatesAutoresizingMaskIntoConstraints = false
        tagSelectionRow.orientation = .horizontal
        tagSelectionRow.alignment = .centerY
        tagSelectionRow.spacing = 10

        tagSelectionSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        tagSelectionSummaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        tagSelectionSummaryLabel.lineBreakMode = .byTruncatingTail

        clearTagSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        clearTagSelectionButton.target = self
        clearTagSelectionButton.action = #selector(handleClearTagSelection(_:))
        clearTagSelectionButton.bezelStyle = .rounded

        tagSelectionRow.addArrangedSubview(tagSelectionSummaryLabel)
        tagSelectionRow.addArrangedSubview(clearTagSelectionButton)

        tagCloudContainerView.translatesAutoresizingMaskIntoConstraints = false

        tagCloudScrollView.translatesAutoresizingMaskIntoConstraints = false
        tagCloudScrollView.hasVerticalScroller = true
        tagCloudScrollView.hasHorizontalScroller = false
        tagCloudScrollView.autohidesScrollers = true
        tagCloudScrollView.borderType = .bezelBorder

        tagCloudCollectionView.translatesAutoresizingMaskIntoConstraints = false
        tagCloudCollectionView.dataSource = self
        tagCloudCollectionView.delegate = self
        tagCloudCollectionView.register(
            BookmarkTagCloudItem.self,
            forItemWithIdentifier: BookmarkTagCloudItem.reuseIdentifier
        )
        tagCloudScrollView.documentView = tagCloudCollectionView

        tagCloudEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        tagCloudEmptyStateLabel.alignment = .center
        tagCloudEmptyStateLabel.textColor = .secondaryLabelColor
        tagCloudEmptyStateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        tagCloudEmptyStateLabel.maximumNumberOfLines = 2
        tagCloudEmptyStateLabel.lineBreakMode = .byWordWrapping

        tagCloudContainerView.addSubview(tagCloudScrollView)
        tagCloudContainerView.addSubview(tagCloudEmptyStateLabel)

        matchingClipsCountLabel.translatesAutoresizingMaskIntoConstraints = false
        matchingClipsCountLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        matchingClipsCountLabel.textColor = .secondaryLabelColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleTableAction(_:))
        tableView.doubleAction = #selector(handleTableAction(_:))
        tableView.onReturnKey = { [weak self] in
            self?.openSelectedBookmark()
        }
        tableView.onDeleteKey = { [weak self] in
            self?.removeSelectedBookmark()
        }
        tableView.onScrollWheel = { [weak self] in
            self?.refreshHoveredThumbnailPreview()
        }

        let thumbnailColumn = NSTableColumn(identifier: ColumnIdentifier.thumbnail)
        thumbnailColumn.title = "Bookmark"
        thumbnailColumn.minWidth = 140
        thumbnailColumn.width = 156
        thumbnailColumn.maxWidth = 156
        thumbnailColumn.resizingMask = []

        let timeColumn = NSTableColumn(identifier: ColumnIdentifier.time)
        timeColumn.title = "Time"
        timeColumn.minWidth = 110
        timeColumn.width = 120
        timeColumn.resizingMask = []

        let filenameColumn = NSTableColumn(identifier: ColumnIdentifier.filename)
        filenameColumn.title = "Filename"
        filenameColumn.minWidth = 180
        filenameColumn.width = 280
        filenameColumn.resizingMask = .autoresizingMask

        let importedDateColumn = NSTableColumn(identifier: ColumnIdentifier.importedDate)
        importedDateColumn.title = "Imported Date"
        importedDateColumn.minWidth = 180
        importedDateColumn.width = 190
        importedDateColumn.resizingMask = []
        importedDateColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: SortDescriptorKey.importedAt,
            ascending: false
        )

        let fileCreatedDateColumn = NSTableColumn(identifier: ColumnIdentifier.fileCreatedDate)
        fileCreatedDateColumn.title = "File Created"
        fileCreatedDateColumn.minWidth = 180
        fileCreatedDateColumn.width = 190
        fileCreatedDateColumn.resizingMask = []
        fileCreatedDateColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: SortDescriptorKey.fileCreatedAt,
            ascending: false
        )

        let tagsColumn = NSTableColumn(identifier: ColumnIdentifier.tags)
        tagsColumn.title = "Tags"
        tagsColumn.minWidth = 210
        tagsColumn.width = 240
        tagsColumn.resizingMask = []

        let protectedColumn = NSTableColumn(identifier: ColumnIdentifier.protected)
        protectedColumn.title = "Private"
        protectedColumn.minWidth = 72
        protectedColumn.width = 78
        protectedColumn.maxWidth = 84
        protectedColumn.resizingMask = []

        let actionsColumn = NSTableColumn(identifier: ColumnIdentifier.actions)
        actionsColumn.title = ""
        actionsColumn.minWidth = 48
        actionsColumn.maxWidth = 56
        actionsColumn.width = 52
        actionsColumn.minWidth = 52
        actionsColumn.maxWidth = 52
        actionsColumn.resizingMask = []

        let removeColumn = NSTableColumn(identifier: ColumnIdentifier.remove)
        removeColumn.title = ""
        removeColumn.minWidth = 48
        removeColumn.maxWidth = 56
        removeColumn.width = 52
        removeColumn.minWidth = 52
        removeColumn.maxWidth = 52
        removeColumn.resizingMask = []

        tableView.addTableColumn(thumbnailColumn)
        tableView.addTableColumn(timeColumn)
        tableView.addTableColumn(filenameColumn)
        tableView.addTableColumn(importedDateColumn)
        tableView.addTableColumn(fileCreatedDateColumn)
        tableView.addTableColumn(protectedColumn)
        tableView.addTableColumn(tagsColumn)
        tableView.addTableColumn(actionsColumn)
        tableView.addTableColumn(removeColumn)
        scrollView.documentView = tableView

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)

        contentView.addSubview(controlsRow)
        contentView.addSubview(contentStackView)
        contentView.addSubview(emptyStateLabel)

        contentStackView.addArrangedSubview(tagSelectionRow)
        contentStackView.addArrangedSubview(tagCloudContainerView)
        contentStackView.addArrangedSubview(matchingClipsCountLabel)
        contentStackView.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            controlsRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            controlsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            controlsRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            contentStackView.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 12),
            contentStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            contentStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            contentStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),

            tagSelectionRow.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            tagCloudContainerView.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            matchingClipsCountLabel.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStackView.widthAnchor),

            tagCloudScrollView.topAnchor.constraint(equalTo: tagCloudContainerView.topAnchor),
            tagCloudScrollView.leadingAnchor.constraint(equalTo: tagCloudContainerView.leadingAnchor),
            tagCloudScrollView.trailingAnchor.constraint(equalTo: tagCloudContainerView.trailingAnchor),
            tagCloudScrollView.bottomAnchor.constraint(equalTo: tagCloudContainerView.bottomAnchor),

            tagCloudEmptyStateLabel.centerXAnchor.constraint(equalTo: tagCloudContainerView.centerXAnchor),
            tagCloudEmptyStateLabel.centerYAnchor.constraint(equalTo: tagCloudContainerView.centerYAnchor),
            tagCloudEmptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tagCloudContainerView.leadingAnchor, constant: 16),
            tagCloudEmptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: tagCloudContainerView.trailingAnchor, constant: -16),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
        ])
        let tagCloudHeightConstraint = tagCloudContainerView.heightAnchor.constraint(equalToConstant: 56)
        tagCloudHeightConstraint.isActive = true
        self.tagCloudHeightConstraint = tagCloudHeightConstraint

        refreshDisplayModeUI()

        rootView.onFileURLsDropped = { [weak self] urls in
            self?.importMedia(from: urls)
        }
    }

    private func installObservers() {
        bookmarkChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarkStoreDidChange,
            object: bookmarkStore,
            queue: .main
        ) { [weak self] _ in
            self?.reloadBookmarks()
        }

        protectedSessionObserver = NotificationCenter.default.addObserver(
            forName: .protectedBookmarksSessionDidChange,
            object: protectedBookmarksSessionController,
            queue: .main
        ) { [weak self] _ in
            self?.handleProtectedSessionStateChange()
        }
    }

    private func installEscKeyMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                let self,
                event.keyCode == 53,
                let window = self.window,
                event.window === window
            else {
                return event
            }
            self.onEscapeKey?()
            return event
        }
    }

    private func installBookmarkNavigationMonitor() {
        bookmarkNavigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard
                let self,
                let window = self.window,
                window.isVisible,
                event.window === window
            else {
                return event
            }

            let disallowedModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
            guard disallowedModifiers.isEmpty else {
                return event
            }

            switch event.keyCode {
            case 49:
                guard !self.isEditingTextField else {
                    return event
                }
                self.onPlayPauseRequested?()
                return nil
            case 126:
                self.navigateSelection(delta: -1)
                return nil
            case 125:
                self.navigateSelection(delta: 1)
                return nil
            default:
                return event
            }
        }
    }

    private var isEditingTextField: Bool {
        guard let firstResponder = window?.firstResponder as? NSTextView else {
            return false
        }
        return firstResponder.isFieldEditor
    }

    private func reloadBookmarks(selecting bookmarkID: BookmarkID? = nil) {
        dismissVisiblePreviewPanels()
        refreshScopeControl()
        refreshDisplayModeUI()
        let selectedBookmarkIDs: Set<BookmarkID> = {
            if let bookmarkID {
                return Set([bookmarkID])
            }
            return Set(tableView.selectedRowIndexes.compactMap { row in
                guard row >= 0, row < bookmarks.count else {
                    return nil
                }
                return bookmarks[row].id
            })
        }()

        let searchQuery = searchField.stringValue
        let visibility = bookmarkVisibility
        if currentDisplayMode == .tagBrowser {
            tagCounts = bookmarkStore.tagCounts(
                selectedTags: selectedTags,
                scope: currentScope,
                currentVideoURL: currentVideoURL,
                searchQuery: searchQuery,
                visibility: visibility
            )
            bookmarks = bookmarkStore.bookmarksMatchingSelectedTags(
                selectedTags,
                scope: currentScope,
                currentVideoURL: currentVideoURL,
                searchQuery: searchQuery,
                sort: currentSort,
                visibility: visibility
            )
            updateTagSelectionSummary()
            updateMatchingClipsCount()
            tagCloudCollectionView.reloadData()
            tagCloudCollectionView.layoutSubtreeIfNeeded()
            updateTagCloudHeight()
        } else {
            tagCounts = []
            bookmarks = bookmarkStore.bookmarks(
                scope: currentScope,
                currentVideoURL: currentVideoURL,
                searchQuery: searchQuery,
                sort: currentSort,
                visibility: visibility
            )
            updateTagCloudHeight()
        }

        suppressBookmarkOpenOnSelectionChange = true
        tableView.reloadData()

        let rowsToSelect = selectedBookmarkIDs.reduce(into: IndexSet()) { result, bookmarkID in
            guard let row = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                return
            }
            result.insert(row)
        }

        if let firstSelectedRow = rowsToSelect.first {
            tableView.selectRowIndexes(rowsToSelect, byExtendingSelection: false)
            tableView.scrollRowToVisible(firstSelectedRow)
            if let bookmarkID, pendingRevealHighlightBookmarkID == bookmarkID {
                flashRevealHighlight(forRow: firstSelectedRow, bookmarkID: bookmarkID)
            }
        } else {
            tableView.deselectAll(nil)
            pendingRevealHighlightBookmarkID = nil
        }
        suppressBookmarkOpenOnSelectionChange = false

        updateEmptyState()
    }

    private func updateEmptyState() {
        let message: String
        switch currentDisplayMode {
        case .bookmarks:
            switch currentScope {
            case .currentVideo where currentVideoURL == nil:
                message = "Load a video to view bookmarks for the current clip."
            case .currentVideo:
                message = searchField.stringValue.isEmpty
                    ? "No bookmarks for this video yet."
                    : "No bookmarks match your current search."
            case .allVideos:
                message = searchField.stringValue.isEmpty
                    ? "No bookmarks saved yet."
                    : "No bookmarks match your current search."
            case .imported:
                message = searchField.stringValue.isEmpty
                    ? "No imported media yet."
                    : "No imported media matches your current search."
            case .protected:
                message = searchField.stringValue.isEmpty
                    ? "No protected bookmarks yet."
                    : "No protected bookmarks match your current search."
            }
        case .tagBrowser:
            if currentScope == .currentVideo, currentVideoURL == nil {
                message = "Load a video to explore tags for the current clip."
            } else if selectedTags.isEmpty {
                message = "No clips available for the current tag filters."
            } else {
                message = "No clips match the selected tags."
            }
        }
        emptyStateLabel.stringValue = message
        let isEmpty = bookmarks.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.alphaValue = isEmpty ? 0.78 : 1
        tagCloudEmptyStateLabel.isHidden = currentDisplayMode != .tagBrowser || !tagCounts.isEmpty
    }

    private func openSelectedBookmark() {
        guard tableView.selectedRowIndexes.count == 1,
              let selectedRow = tableView.selectedRowIndexes.first,
              selectedRow >= 0,
              selectedRow < bookmarks.count else {
            return
        }
        dismissVisiblePreviewPanels()
        onOpenBookmark?(bookmarks[selectedRow])
    }

    private func removeSelectedBookmark() {
        let selectedBookmarkIDs: Set<BookmarkID> = Set(tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < bookmarks.count else {
                return nil
            }
            return bookmarks[row].id
        })
        guard !selectedBookmarkIDs.isEmpty else {
            return
        }
        bookmarkStore.removeBookmarks(ids: selectedBookmarkIDs)
    }

    private func removeBookmark(at row: Int) {
        guard row >= 0, row < bookmarks.count else {
            return
        }
        if tableView.selectedRowIndexes.contains(row), tableView.selectedRowIndexes.count > 1 {
            removeSelectedBookmark()
            return
        }
        bookmarkStore.removeBookmark(id: bookmarks[row].id)
    }

    private func selectThumbnailFrame(for bookmarkID: BookmarkID) {
        guard let bookmark = bookmarkStore.bookmark(for: bookmarkID) else {
            return
        }
        presentThumbnailPicker(for: bookmark)
    }

    private func revealBookmarkInFinder(for bookmarkID: BookmarkID) {
        guard let bookmark = bookmarkStore.bookmark(for: bookmarkID) else {
            return
        }

        let videoURL = bookmark.videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            showInfoAlert(
                title: "File Not Found",
                message: "\"\(bookmark.videoDisplayName)\" is no longer available at its saved location."
            )
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([videoURL])
    }

    private func presentThumbnailPicker(for bookmark: Bookmark) {
        guard let window else {
            return
        }

        if let existingSheetController = activeThumbnailPickerSheetController,
           existingSheetController.bookmarkID == bookmark.id {
            window.makeKeyAndOrderFront(nil)
            return
        }

        activeThumbnailPickerSheetController?.cancelAndClose()
        activeThumbnailPickerSheetController = nil

        let sheetController = BookmarkThumbnailPickerSheetController(
            bookmark: bookmark
        )
        sheetController.onSave = { [weak self] bookmarkID, selectedTimeSeconds, originalBookmarkTimeSeconds in
            let normalizedTimeSeconds: PlaybackSeconds? =
                abs(selectedTimeSeconds - originalBookmarkTimeSeconds) < 0.001 ? nil : selectedTimeSeconds
            self?.bookmarkStore.updateThumbnailTimeSeconds(
                for: bookmarkID,
                thumbnailTimeSeconds: normalizedTimeSeconds
            )
        }
        sheetController.onClose = { [weak self] controller in
            guard self?.activeThumbnailPickerSheetController === controller else {
                return
            }
            self?.activeThumbnailPickerSheetController = nil
        }

        activeThumbnailPickerSheetController = sheetController
        window.beginSheet(sheetController.window!, completionHandler: nil)
    }

    @objc
    private func handleScopeChanged(_ sender: NSSegmentedControl) {
        currentScope = BookmarkListScope(rawValue: sender.selectedSegment) ?? fallbackScopeForLockedSession()
        reloadBookmarks()
        persistViewStateIfNeeded()
    }

    @objc
    private func handleDisplayModeChanged(_ sender: NSSegmentedControl) {
        currentDisplayMode = DisplayMode(rawValue: sender.selectedSegment) ?? .bookmarks
        reloadBookmarks()
        persistViewStateIfNeeded()
    }

    @objc
    private func handleClearTagSelection(_ sender: Any?) {
        _ = sender
        guard !selectedTags.isEmpty else {
            return
        }
        selectedTags = []
        reloadBookmarks()
        persistViewStateIfNeeded()
    }

    @objc
    private func handleImportMedia(_ sender: Any?) {
        _ = sender
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK else { return }
            self?.importMedia(from: panel.urls)
        }
    }

    @objc
    private func handleTableAction(_ sender: Any?) {
        _ = sender
        let clickedColumn = tableView.clickedColumn
        let tagsColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.tags)
        let protectedColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.protected)
        let actionsColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.actions)
        let removeColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.remove)
        if clickedColumn == tagsColumnIndex
            || clickedColumn == protectedColumnIndex
            || clickedColumn == actionsColumnIndex
            || clickedColumn == removeColumnIndex {
            return
        }
        openSelectedBookmark()
    }

    private func importMedia(from urls: [URL]) {
        let validVideoURLs = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter(isVideoURL(_:))
        guard !validVideoURLs.isEmpty else {
            return
        }

        let importPlan = bookmarkStore.prepareImportedMediaImport(videoURLs: validVideoURLs)
        guard !importPlan.isEmpty else {
            return
        }

        let duplicateResolutionsByVideoPath: [String: ImportedMediaDuplicateResolution]
        if importPlan.duplicates.isEmpty {
            duplicateResolutionsByVideoPath = [:]
        } else {
            guard let collectedResolutions = collectDuplicateResolutions(for: importPlan) else {
                return
            }
            duplicateResolutionsByVideoPath = collectedResolutions
        }

        let importResult = bookmarkStore.applyImportedMediaImport(
            plan: importPlan,
            duplicateResolutionsByVideoPath: duplicateResolutionsByVideoPath
        )

        guard
            let selectedBookmarkID = importResult.affectedBookmarkIDs.first ?? importResult.firstDuplicateBookmarkID
        else {
            return
        }

        currentScope = importPlan.duplicates.isEmpty ? .imported : .allVideos
        scopeControl.selectedSegment = currentScope.rawValue
        reloadBookmarks(selecting: selectedBookmarkID)
    }

    private func collectDuplicateResolutions(
        for importPlan: ImportedMediaImportPlan
    ) -> [String: ImportedMediaDuplicateResolution]? {
        var duplicateResolutionsByVideoPath: [String: ImportedMediaDuplicateResolution] = [:]
        var bulkResolution: ImportedMediaDuplicateResolution?

        for (index, duplicate) in importPlan.duplicates.enumerated() {
            if let bulkResolution {
                duplicateResolutionsByVideoPath[duplicate.normalizedVideoPath] = bulkResolution
                continue
            }

            if let existingBookmark = bookmarkStore.bookmark(for: duplicate.existingBookmarkID) {
                revealBookmark(existingBookmark, preferredScope: .allVideos, highlight: true)
            }

            switch promptForDuplicateImportAction(
                duplicate,
                duplicateIndex: index,
                totalDuplicates: importPlan.duplicates.count
            ) {
            case .replace:
                duplicateResolutionsByVideoPath[duplicate.normalizedVideoPath] = .replace
            case .replaceAll:
                duplicateResolutionsByVideoPath[duplicate.normalizedVideoPath] = .replace
                bulkResolution = .replace
            case .skip:
                duplicateResolutionsByVideoPath[duplicate.normalizedVideoPath] = .skip
            case .skipAll:
                duplicateResolutionsByVideoPath[duplicate.normalizedVideoPath] = .skip
                bulkResolution = .skip
            case .cancel:
                return nil
            }
        }

        return duplicateResolutionsByVideoPath
    }

    private func promptForDuplicateImportAction(
        _ duplicate: ImportedMediaDuplicate,
        duplicateIndex: Int,
        totalDuplicates: Int
    ) -> ImportedMediaDuplicatePromptAction {
        let alert = NSAlert()
        let videoName = duplicate.videoURL.lastPathComponent
        let isSingleDuplicate = totalDuplicates == 1
        let duplicateProgressMessage = totalDuplicates > 1 ? "Duplicate \(duplicateIndex + 1) of \(totalDuplicates)." : nil

        alert.messageText = "\"\(videoName)\" is already imported."
        if isSingleDuplicate {
            alert.informativeText = [
                duplicateProgressMessage,
                "Replace will refresh the existing imported bookmark. Skip will keep the current bookmark unchanged."
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        } else {
            alert.informativeText = [
                duplicateProgressMessage,
                "Replace updates just this bookmark. Replace All or Skip All will apply the same choice to the remaining duplicates while still importing any new media from this batch."
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }

        if isSingleDuplicate {
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Replace All")
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Skip All")
            alert.addButton(withTitle: "Cancel")
        }

        guard let window else {
            return .cancel
        }

        window.makeKeyAndOrderFront(nil)
        let response = alert.runModal()

        if isSingleDuplicate {
            switch response.rawValue {
            case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
                return .replace
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                return .skip
            default:
                return .cancel
            }
        }

        switch response.rawValue {
        case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
            return .replace
        case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
            return .replaceAll
        case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
            return .skip
        case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1:
            return .skipAll
        default:
            return .cancel
        }
    }

    private func revealBookmark(
        _ bookmark: Bookmark,
        preferredScope: BookmarkListScope?,
        highlight: Bool
    ) {
        searchField.stringValue = ""

        if let preferredScope {
            currentScope = preferredScope
        } else if bookmark.videoPath == currentVideoURL?.path {
            currentScope = .currentVideo
        } else {
            currentScope = .allVideos
        }

        scopeControl.selectedSegment = min(currentScope.rawValue, max(scopeControl.segmentCount - 1, 0))
        if highlight {
            pendingRevealHighlightBookmarkID = bookmark.id
        }
        reloadBookmarks(selecting: bookmark.id)
        persistViewStateIfNeeded()
    }

    private func flashRevealHighlight(forRow row: Int, bookmarkID: BookmarkID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingRevealHighlightBookmarkID == bookmarkID else {
                return
            }
            guard let rowView = self.tableView.rowView(atRow: row, makeIfNecessary: true) as? BookmarkTableRowView else {
                return
            }
            rowView.flashRevealHighlight()
            self.pendingRevealHighlightBookmarkID = nil
        }
    }

    private func isVideoURL(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            if values.isDirectory == true {
                return false
            }
            if let contentType = values.contentType {
                return contentType.conforms(to: .movie)
            }
        } catch {
            return false
        }
        return false
    }

    private static func formattedImportedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return importedDateFormatter.string(from: date)
    }

    private static func formattedFileCreatedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return fileCreatedDateFormatter.string(from: date)
    }

    private func bookmarkSort(from sortDescriptors: [NSSortDescriptor]) -> BookmarkSort {
        guard let sortDescriptor = sortDescriptors.first, let key = sortDescriptor.key else {
            return .automatic
        }
        switch key {
        case SortDescriptorKey.importedAt:
            return .importedAt(ascending: sortDescriptor.ascending)
        case SortDescriptorKey.fileCreatedAt:
            return .fileCreatedAt(ascending: sortDescriptor.ascending)
        default:
            return .automatic
        }
    }

    private var bookmarkVisibility: BookmarkVisibility {
        if currentScope == .protected {
            return .protectedOnly
        }
        return protectedBookmarksSessionController.isUnlocked ? .all : .publicOnly
    }

    private func handleProtectedSessionStateChange() {
        if !protectedBookmarksSessionController.isUnlocked, currentScope == .protected {
            currentScope = fallbackScopeForLockedSession()
        }
        reloadBookmarks()
    }

    private func refreshScopeControl() {
        let labels = protectedBookmarksSessionController.isUnlocked
            ? ["Current Video", "All Videos", "Imported", "Protected"]
            : ["Current Video", "All Videos", "Imported"]
        scopeControl.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            scopeControl.setLabel(label, forSegment: index)
        }

        if !protectedBookmarksSessionController.isUnlocked, currentScope == .protected {
            currentScope = fallbackScopeForLockedSession()
        }

        scopeControl.selectedSegment = min(currentScope.rawValue, labels.count - 1)
    }

    private func fallbackScopeForLockedSession() -> BookmarkListScope {
        currentVideoURL == nil ? .allVideos : .currentVideo
    }

    private func refreshDisplayModeUI() {
        let isTagBrowser = currentDisplayMode == .tagBrowser
        modeControl.selectedSegment = currentDisplayMode.rawValue
        tagSelectionRow.isHidden = !isTagBrowser
        tagCloudContainerView.isHidden = !isTagBrowser
        matchingClipsCountLabel.isHidden = !isTagBrowser
        updateTagCloudHeight()
    }

    private func updateTagSelectionSummary() {
        if selectedTags.isEmpty {
            tagSelectionSummaryLabel.stringValue = "Showing all visible clips. Select tags to narrow the list."
        } else {
            tagSelectionSummaryLabel.stringValue = "Filtering by: \(selectedTags.joined(separator: " + "))"
        }
        clearTagSelectionButton.isHidden = selectedTags.isEmpty
    }

    private func updateMatchingClipsCount() {
        let clipLabel = bookmarks.count == 1 ? "clip" : "clips"
        matchingClipsCountLabel.stringValue = "\(bookmarks.count) matching \(clipLabel)"
    }

    private func toggleTagSelection(_ tag: String) {
        let normalizedTag = tag.localizedLowercase
        if let existingIndex = selectedTags.firstIndex(where: { $0.localizedLowercase == normalizedTag }) {
            selectedTags.remove(at: existingIndex)
        } else {
            selectedTags.append(tag)
            selectedTags.sort { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
        reloadBookmarks()
        persistViewStateIfNeeded()
    }

    private func isTagSelected(_ tag: String) -> Bool {
        let normalizedTag = tag.localizedLowercase
        return selectedTags.contains { $0.localizedLowercase == normalizedTag }
    }

    private func updateTagCloudHeight() {
        guard let tagCloudHeightConstraint else {
            return
        }
        guard currentDisplayMode == .tagBrowser else {
            tagCloudHeightConstraint.constant = 0
            return
        }

        let minimumHeight: CGFloat = tagCounts.isEmpty ? 56 : 44
        let maximumHeight: CGFloat = 160
        let contentHeight = tagCloudCollectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        tagCloudHeightConstraint.constant = min(max(contentHeight, minimumHeight), maximumHeight)
    }

    private func dismissVisiblePreviewPanels() {
        activePreviewThumbnailCell = nil
        for row in 0..<tableView.numberOfRows {
            guard let view = tableView.view(
                atColumn: tableView.column(withIdentifier: ColumnIdentifier.thumbnail),
                row: row,
                makeIfNecessary: false
            ) as? BookmarkThumbnailCellView else {
                continue
            }
            view.dismissPreview()
        }
    }

    private func refreshHoveredThumbnailPreview() {
        guard let window else {
            dismissVisiblePreviewPanels()
            return
        }

        let mouseLocationInTable = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let thumbnailColumn = tableView.column(withIdentifier: ColumnIdentifier.thumbnail)
        let hoveredRow = tableView.row(at: mouseLocationInTable)
        let hoveredColumn = tableView.column(at: mouseLocationInTable)

        guard hoveredRow >= 0,
              hoveredColumn == thumbnailColumn,
              let hoveredCell = tableView.view(
                atColumn: thumbnailColumn,
                row: hoveredRow,
                makeIfNecessary: false
              ) as? BookmarkThumbnailCellView,
              hoveredCell.isMouseInsideThumbnailOnScreen() else {
            dismissVisiblePreviewPanels()
            return
        }

        if activePreviewThumbnailCell !== hoveredCell {
            activePreviewThumbnailCell?.dismissPreview()
        }
        hoveredCell.refreshPreviewForCurrentHover()
    }

    private func previewWillOpen(from cell: BookmarkThumbnailCellView) {
        guard activePreviewThumbnailCell !== cell else {
            return
        }
        activePreviewThumbnailCell?.dismissPreview()
        activePreviewThumbnailCell = cell
    }

    private func previewDidClose(from cell: BookmarkThumbnailCellView) {
        guard activePreviewThumbnailCell === cell else {
            return
        }
        activePreviewThumbnailCell = nil
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension BookmarksWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        _ = tableView
        return bookmarks.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        _ = row
        let identifier = NSUserInterfaceItemIdentifier("BookmarkTableRowView")
        if let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkTableRowView {
            return rowView
        }
        let rowView = BookmarkTableRowView(frame: .zero)
        rowView.identifier = identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        _ = tableView
        _ = row
        return 64
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < bookmarks.count, let tableColumn else {
            return nil
        }

        let bookmark = bookmarks[row]
        switch tableColumn.identifier {
        case ColumnIdentifier.thumbnail:
            let cell = reusableThumbnailCell(in: tableView)
            cell.configure(bookmark: bookmark, thumbnailService: thumbnailService)
            return cell
        case ColumnIdentifier.time:
            let cell = reusableTimeCell(in: tableView)
            cell.configure(timestamp: BookmarkStore.formattedTimestamp(bookmark.timeSeconds))
            return cell
        case ColumnIdentifier.filename:
            let cell = reusableFilenameCell(in: tableView)
            cell.configure(filename: bookmark.videoDisplayName)
            return cell
        case ColumnIdentifier.importedDate:
            let cell = reusableDateCell(in: tableView, identifier: "BookmarkImportedDateCellView")
            cell.configure(value: Self.formattedImportedDate(bookmark.importedAt))
            return cell
        case ColumnIdentifier.fileCreatedDate:
            let cell = reusableDateCell(in: tableView, identifier: "BookmarkFileCreatedDateCellView")
            cell.configure(value: Self.formattedFileCreatedDate(bookmark.fileCreatedAt))
            return cell
        case ColumnIdentifier.protected:
            let cell = reusableProtectedCell(in: tableView)
            cell.configure(bookmark: bookmark) { [weak self] bookmarkID, isProtected in
                self?.suppressBookmarkOpenOnSelectionChange = true
                self?.bookmarkStore.updateProtection(for: bookmarkID, isProtected: isProtected)
            }
            return cell
        case ColumnIdentifier.tags:
            let cell = reusableTagsCell(in: tableView)
            cell.configure(bookmark: bookmark, delegate: self) { [weak self] in
                self?.suppressBookmarkOpenOnSelectionChange = true
            }
            return cell
        case ColumnIdentifier.actions:
            let cell = reusableActionsCell(in: tableView)
            cell.configure(bookmark: bookmark, row: row) { [weak self] action in
                guard let self else { return }
                self.suppressBookmarkOpenOnSelectionChange = true
                switch action {
                case let .selectThumbnailFrame(bookmarkID):
                    self.selectThumbnailFrame(for: bookmarkID)
                case let .showInFinder(bookmarkID):
                    self.revealBookmarkInFinder(for: bookmarkID)
                }
            }
            return cell
        case ColumnIdentifier.remove:
            let cell = reusableRemoveCell(in: tableView)
            cell.configure(row: row) { [weak self] selectedRow in
                self?.removeBookmark(at: selectedRow)
            }
            return cell
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        _ = notification
        let tagsColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.tags)
        let protectedColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.protected)
        let actionsColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.actions)
        let removeColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.remove)
        let interactionColumn = tableView.mouseDownColumn
        if interactionColumn == tagsColumnIndex
            || interactionColumn == protectedColumnIndex
            || interactionColumn == actionsColumnIndex
            || interactionColumn == removeColumnIndex {
            suppressBookmarkOpenOnSelectionChange = false
            return
        }
        guard !suppressBookmarkOpenOnSelectionChange else {
            suppressBookmarkOpenOnSelectionChange = false
            return
        }
        guard window?.firstResponder !== tableView.currentEditor() else {
            return
        }
        persistViewStateIfNeeded()
        openSelectedBookmark()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        _ = oldDescriptors
        currentSort = bookmarkSort(from: tableView.sortDescriptors)
        reloadBookmarks()
    }

    private func reusableThumbnailCell(in tableView: NSTableView) -> BookmarkThumbnailCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkThumbnailCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkThumbnailCellView {
            cell.onPreviewWillOpen = { [weak self] previewCell in
                self?.previewWillOpen(from: previewCell)
            }
            cell.onPreviewDidClose = { [weak self] previewCell in
                self?.previewDidClose(from: previewCell)
            }
            return cell
        }
        let cell = BookmarkThumbnailCellView(frame: .zero)
        cell.identifier = identifier
        cell.onPreviewWillOpen = { [weak self] previewCell in
            self?.previewWillOpen(from: previewCell)
        }
        cell.onPreviewDidClose = { [weak self] previewCell in
            self?.previewDidClose(from: previewCell)
        }
        return cell
    }

    private func reusableTimeCell(in tableView: NSTableView) -> BookmarkTimeCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkTimeCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkTimeCellView {
            return cell
        }
        let cell = BookmarkTimeCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func reusableDateCell(
        in tableView: NSTableView,
        identifier: String
    ) -> BookmarkDateCellView {
        let reusableIdentifier = NSUserInterfaceItemIdentifier(identifier)
        if let cell = tableView.makeView(withIdentifier: reusableIdentifier, owner: self) as? BookmarkDateCellView {
            return cell
        }
        let cell = BookmarkDateCellView(frame: .zero)
        cell.identifier = reusableIdentifier
        return cell
    }

    private func reusableProtectedCell(in tableView: NSTableView) -> BookmarkProtectedCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkProtectedCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkProtectedCellView {
            return cell
        }
        let cell = BookmarkProtectedCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func reusableTagsCell(in tableView: NSTableView) -> BookmarkTagsCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkTagsCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkTagsCellView {
            return cell
        }
        let cell = BookmarkTagsCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func reusableFilenameCell(in tableView: NSTableView) -> BookmarkFilenameCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkFilenameCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkFilenameCellView {
            return cell
        }
        let cell = BookmarkFilenameCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func reusableActionsCell(in tableView: NSTableView) -> BookmarkActionsCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkActionsCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkActionsCellView {
            return cell
        }
        let cell = BookmarkActionsCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }

    private func reusableRemoveCell(in tableView: NSTableView) -> BookmarkRemoveCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkRemoveCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkRemoveCellView {
            return cell
        }
        let cell = BookmarkRemoveCellView(frame: .zero)
        cell.identifier = identifier
        return cell
    }
}

extension BookmarksWindowController: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        _ = collectionView
        _ = section
        return tagCounts.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard
            let item = collectionView.makeItem(
                withIdentifier: BookmarkTagCloudItem.reuseIdentifier,
                for: indexPath
            ) as? BookmarkTagCloudItem
        else {
            return NSCollectionViewItem()
        }

        let tagCount = tagCounts[indexPath.item]
        item.configure(
            tagCount: tagCount,
            isSelected: isTagSelected(tagCount.tag)
        ) { [weak self] tag in
            self?.toggleTagSelection(tag)
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        _ = collectionView
        _ = collectionViewLayout
        let tagCount = tagCounts[indexPath.item]
        let title = BookmarkTagCloudItem.displayTitle(for: tagCount)
        let titleWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        ).width
        return NSSize(width: ceil(titleWidth) + 34, height: 32)
    }
}

extension BookmarksWindowController: NSSearchFieldDelegate, NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else {
            return
        }
        reloadBookmarks()
        persistViewStateIfNeeded()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? BookmarkTagsTextField, let bookmarkID = textField.bookmarkID else {
            return
        }
        bookmarkStore.updateTags(for: bookmarkID, tags: BookmarkStore.tags(from: textField.stringValue))
    }
}

private final class BookmarkTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onScrollWheel: (() -> Void)?
    private(set) var mouseDownColumn: Int = -1

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownColumn = column(at: point)
        super.mouseDown(with: event)
        mouseDownColumn = -1
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onReturnKey?()
        case 51, 117:
            onDeleteKey?()
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollWheel?()
    }
}

private final class BookmarkTagCloudItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("BookmarkTagCloudItem")

    private let tagButton = NSButton(title: "", target: nil, action: nil)
    private var tagValue = ""
    private var onToggle: ((String) -> Void)?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.translatesAutoresizingMaskIntoConstraints = false

        tagButton.translatesAutoresizingMaskIntoConstraints = false
        tagButton.setButtonType(.toggle)
        tagButton.bezelStyle = .rounded
        tagButton.isBordered = false
        tagButton.font = .systemFont(ofSize: 13, weight: .semibold)
        tagButton.target = self
        tagButton.action = #selector(handleToggle(_:))
        tagButton.wantsLayer = true
        tagButton.layer?.cornerRadius = 8
        tagButton.layer?.masksToBounds = true

        view.addSubview(tagButton)
        NSLayoutConstraint.activate([
            tagButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tagButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tagButton.topAnchor.constraint(equalTo: view.topAnchor),
            tagButton.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func configure(
        tagCount: BookmarkTagCount,
        isSelected: Bool,
        onToggle: @escaping (String) -> Void
    ) {
        tagValue = tagCount.tag
        self.onToggle = onToggle
        tagButton.title = Self.displayTitle(for: tagCount)
        tagButton.state = isSelected ? .on : .off
        tagButton.toolTip = isSelected
            ? "Click to remove \(tagCount.tag) from the current filter"
            : "Click to filter clips tagged \(tagCount.tag)"
        updateSelectionAppearance(isSelected: isSelected)
    }

    static func displayTitle(for tagCount: BookmarkTagCount) -> String {
        "\(tagCount.tag) \(tagCount.count)"
    }

    @objc
    private func handleToggle(_ sender: NSButton) {
        _ = sender
        onToggle?(tagValue)
    }

    private func updateSelectionAppearance(isSelected: Bool) {
        if isSelected {
            tagButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            tagButton.contentTintColor = .white
        } else {
            tagButton.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            tagButton.contentTintColor = NSColor.labelColor
        }
    }
}

private final class BookmarkTableRowView: NSTableRowView {
    private let revealHighlightView = BookmarkRowHighlightView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        revealHighlightView.autoresizingMask = [.width, .height]
        revealHighlightView.isHidden = true
        addSubview(revealHighlightView, positioned: .above, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        revealHighlightView.frame = bounds.insetBy(dx: 4, dy: 2)
    }

    func flashRevealHighlight() {
        revealHighlightView.layer?.removeAllAnimations()
        revealHighlightView.alphaValue = 0.78
        revealHighlightView.isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            revealHighlightView.animator().alphaValue = 0
        } completionHandler: {
            self.revealHighlightView.alphaValue = 0
            self.revealHighlightView.isHidden = true
        }
    }
}

private final class BookmarkRowHighlightView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        _ = point
        return nil
    }
}

private final class BookmarkThumbnailCellView: NSTableCellView {
    var onPreviewWillOpen: ((BookmarkThumbnailCellView) -> Void)?
    var onPreviewDidClose: ((BookmarkThumbnailCellView) -> Void)?

    private let thumbnailImageView = NSImageView(frame: .zero)
    private let previewImageView = NSImageView(frame: .zero)
    private let previewPanel = BookmarkPreviewPanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let previewContentView = BookmarkPreviewTrackingView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
    private var bookmarkID: BookmarkID?
    private var currentVideoURL: URL?
    private var currentTimeSeconds: PlaybackSeconds = 0
    private weak var thumbnailService: VideoThumbnailService?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false
    private var hasLoadedHighResolutionPreview = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.imageAlignment = .alignCenter
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 6
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.15,
            alpha: 0.85
        ).cgColor

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignCenter

        previewContentView.wantsLayer = true
        previewContentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        previewContentView.layer?.cornerRadius = 12
        previewContentView.layer?.masksToBounds = true
        previewContentView.onLayout = { [weak self] bounds in
            guard let self else { return }
            self.previewImageView.frame = bounds.insetBy(dx: 12, dy: 12)
        }
        previewContentView.addSubview(previewImageView)
        previewPanel.contentView = previewContentView
        previewPanel.backgroundColor = .clear
        previewPanel.isOpaque = false
        previewPanel.hasShadow = true
        previewPanel.hidesOnDeactivate = false
        previewPanel.level = .floating

        addSubview(thumbnailImageView)
        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnailImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumbnailImageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            thumbnailImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            dismissPreview()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        _ = event
        isHovering = true
        showPreviewIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        guard !isMouseInsideThumbnailOnScreen() else {
            return
        }
        isHovering = false
        dismissPreview()
    }

    func configure(bookmark: Bookmark, thumbnailService: VideoThumbnailService) {
        bookmarkID = bookmark.id
        currentVideoURL = bookmark.videoURL
        currentTimeSeconds = bookmark.effectiveThumbnailTimeSeconds
        self.thumbnailService = thumbnailService
        hasLoadedHighResolutionPreview = false
        isHovering = false
        thumbnailImageView.image = Self.placeholderImage
        previewImageView.image = Self.placeholderImage
        previewPanel.orderOut(nil)
        thumbnailService.requestThumbnail(
            for: bookmark.videoURL,
            at: bookmark.effectiveThumbnailTimeSeconds,
            maximumSize: CGSize(width: 256, height: 144)
        ) { [weak self] image in
            guard let self, self.bookmarkID == bookmark.id else { return }
            let resolvedImage = image ?? Self.placeholderImage
            self.thumbnailImageView.image = resolvedImage
            self.previewImageView.image = resolvedImage
            self.updatePreviewSize(for: resolvedImage)
            if self.isHovering {
                self.showPreviewIfNeeded()
            }
        }
    }

    func dismissPreview() {
        isHovering = false
        if previewPanel.isVisible {
            previewPanel.orderOut(nil)
            onPreviewDidClose?(self)
            return
        }
        previewPanel.orderOut(nil)
    }

    func refreshPreviewForCurrentHover() {
        let isPointerInsideThumbnail = isMouseInsideThumbnailOnScreen()
        isHovering = isPointerInsideThumbnail
        if isPointerInsideThumbnail {
            showPreviewIfNeeded()
        } else {
            dismissPreview()
        }
    }

    private func showPreviewIfNeeded() {
        guard let image = previewImageView.image else {
            return
        }
        updatePreviewSize(for: image)
        requestHighResolutionPreviewIfNeeded()
        guard window != nil else {
            return
        }
        onPreviewWillOpen?(self)
        if previewPanel.isVisible {
            positionPreviewPanel(for: previewContentView.frame.size)
            return
        }
        positionPreviewPanel(for: previewContentView.frame.size)
        previewPanel.orderFront(nil)
    }

    private func updatePreviewSize(for image: NSImage) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            applyPreviewContentSize(NSSize(width: 480, height: 300))
            return
        }
        let screenFrame = previewScreenVisibleFrame ?? NSScreen.main?.visibleFrame
        let maxContentWidth = max(270, floor((screenFrame?.width ?? 1080) * 0.25))
        let maxContentHeight = max(150, floor((screenFrame?.height ?? 720) * 0.25))
        let widthScale = maxContentWidth / imageSize.width
        let heightScale = maxContentHeight / imageSize.height
        let scale = min(widthScale, heightScale, 1)
        let contentWidth = max(270, floor(imageSize.width * scale))
        let contentHeight = max(150, floor(imageSize.height * scale))
        applyPreviewContentSize(NSSize(width: contentWidth + 24, height: contentHeight + 24))
    }

    private func requestHighResolutionPreviewIfNeeded() {
        guard !hasLoadedHighResolutionPreview,
              let bookmarkID,
              let currentVideoURL,
              let thumbnailService else {
            return
        }
        hasLoadedHighResolutionPreview = true
        thumbnailService.requestThumbnail(for: currentVideoURL, at: currentTimeSeconds, maximumSize: nil) { [weak self] image in
            guard let self, self.bookmarkID == bookmarkID, let image else { return }
            self.previewImageView.image = image
            self.updatePreviewSize(for: image)
        }
    }

    private var thumbnailFrameOnScreen: NSRect? {
        guard let window else {
            return nil
        }
        let frameInWindow = convert(bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func isMouseInsideThumbnailOnScreen() -> Bool {
        guard let thumbnailFrameOnScreen else {
            return false
        }
        return thumbnailFrameOnScreen.contains(NSEvent.mouseLocation)
    }

    private var previewScreenVisibleFrame: NSRect? {
        window?.screen?.visibleFrame
            ?? thumbnailImageView.window?.screen?.visibleFrame
    }

    private func applyPreviewContentSize(_ size: NSSize) {
        previewContentView.setFrameSize(size)
        previewImageView.frame = previewContentView.bounds.insetBy(dx: 12, dy: 12)
        previewContentView.layoutSubtreeIfNeeded()
        previewPanel.setContentSize(size)
        if previewPanel.isVisible {
            positionPreviewPanel(for: size)
        }
    }

    private func positionPreviewPanel(for size: NSSize) {
        guard let thumbnailFrameOnScreen else { return }
        let screenFrame = previewScreenVisibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(
            max(screenFrame.minX, thumbnailFrameOnScreen.maxX + 12),
            screenFrame.maxX - size.width
        )
        let y = min(
            max(screenFrame.minY, thumbnailFrameOnScreen.midY - (size.height / 2)),
            screenFrame.maxY - size.height
        )
        previewPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private static let placeholderImage: NSImage = {
        let size = NSSize(width: 128, height: 72)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let symbolRect = NSRect(x: 44, y: 20, width: 40, height: 32)
        if let symbol = NSImage(
            systemSymbolName: "bookmark.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) {
            symbol.draw(in: symbolRect)
        }
        image.unlockFocus()
        return image
    }()
}

private final class BookmarkPreviewPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class BookmarkPreviewTrackingView: NSView {
    var onLayout: ((NSRect) -> Void)?

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
}

private final class BookmarkTimeCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)

        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(timestamp: String) {
        titleLabel.stringValue = timestamp
    }
}

private final class BookmarkDateCellView: NSTableCellView {
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 13, weight: .regular)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.textColor = .secondaryLabelColor

        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(value: String) {
        valueLabel.stringValue = value
    }
}

private final class BookmarkFilenameCellView: NSTableCellView {
    private let filenameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.font = .systemFont(ofSize: 13, weight: .regular)
        filenameLabel.textColor = .secondaryLabelColor
        filenameLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(filenameLabel)
        NSLayoutConstraint.activate([
            filenameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filenameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(filename: String) {
        filenameLabel.stringValue = filename
    }
}

private final class BookmarkTagsCellView: NSTableCellView {
    let tagsTextField = BookmarkTagsTextField(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        tagsTextField.translatesAutoresizingMaskIntoConstraints = false
        tagsTextField.isEditable = true
        tagsTextField.isSelectable = true
        tagsTextField.isBordered = true
        tagsTextField.isBezeled = true
        tagsTextField.placeholderString = "Add tags separated by commas"
        tagsTextField.focusRingType = .default

        addSubview(tagsTextField)
        NSLayoutConstraint.activate([
            tagsTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tagsTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tagsTextField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        bookmark: Bookmark,
        delegate: NSTextFieldDelegate,
        onInteraction: @escaping () -> Void
    ) {
        tagsTextField.bookmarkID = bookmark.id
        tagsTextField.delegate = delegate
        tagsTextField.onInteraction = onInteraction
        tagsTextField.stringValue = BookmarkStore.tagString(from: bookmark.tags)
    }
}

private final class BookmarkProtectedCellView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var bookmarkID: BookmarkID?
    private var onToggle: ((BookmarkID, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.target = self
        checkbox.action = #selector(handleToggle(_:))
        checkbox.toolTip = "Hide this bookmark until protected media is unlocked"

        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(bookmark: Bookmark, onToggle: @escaping (BookmarkID, Bool) -> Void) {
        bookmarkID = bookmark.id
        checkbox.state = bookmark.isProtected ? .on : .off
        self.onToggle = onToggle
    }

    @objc
    private func handleToggle(_ sender: NSButton) {
        guard let bookmarkID else { return }
        onToggle?(bookmarkID, sender.state == .on)
    }
}

private enum BookmarkRowAction {
    case selectThumbnailFrame(BookmarkID)
    case showInFinder(BookmarkID)
}

private final class BookmarkActionsCellView: NSTableCellView {
    private let actionsButton = NSButton(title: "", target: nil, action: nil)
    private var bookmarkID: BookmarkID?
    private var row: Int?
    private var onAction: ((BookmarkRowAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        actionsButton.translatesAutoresizingMaskIntoConstraints = false
        actionsButton.bezelStyle = .smallSquare
        actionsButton.isBordered = false
        configureActionsButtonAppearance()
        actionsButton.target = self
        actionsButton.action = #selector(handleActionsButton(_:))
        actionsButton.toolTip = "Bookmark Actions"

        addSubview(actionsButton)
        NSLayoutConstraint.activate([
            actionsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            actionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configureActionsButtonAppearance() {
        let symbolNames = [
            "ellipsis.vertical.circle",
            "ellipsis.circle",
            "ellipsis"
        ]

        if let image = symbolNames.lazy.compactMap({
            NSImage(systemSymbolName: $0, accessibilityDescription: "Bookmark Actions")
        }).first {
            actionsButton.image = image
            actionsButton.imagePosition = .imageOnly
            actionsButton.title = ""
            return
        }

        actionsButton.image = nil
        actionsButton.title = "⋮"
        actionsButton.font = .systemFont(ofSize: 15, weight: .semibold)
        actionsButton.imagePosition = .noImage
    }

    func configure(
        bookmark: Bookmark,
        row: Int,
        onAction: @escaping (BookmarkRowAction) -> Void
    ) {
        bookmarkID = bookmark.id
        self.row = row
        self.onAction = onAction
    }

    @objc
    private func handleActionsButton(_ sender: NSButton) {
        guard let row else { return }

        if let tableView = enclosingTableView,
           row >= 0,
           !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let menu = NSMenu()

        let selectThumbnailItem = NSMenuItem(
            title: "Select Thumbnail Frame...",
            action: #selector(handleSelectThumbnailFrame(_:)),
            keyEquivalent: ""
        )
        selectThumbnailItem.target = self
        menu.addItem(selectThumbnailItem)

        let showInFinderItem = NSMenuItem(
            title: "Show in Finder",
            action: #selector(handleShowInFinder(_:)),
            keyEquivalent: ""
        )
        showInFinderItem.target = self
        menu.addItem(showInFinderItem)

        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc
    private func handleSelectThumbnailFrame(_ sender: Any?) {
        _ = sender
        guard let bookmarkID else { return }
        onAction?(.selectThumbnailFrame(bookmarkID))
    }

    @objc
    private func handleShowInFinder(_ sender: Any?) {
        _ = sender
        guard let bookmarkID else { return }
        onAction?(.showInFinder(bookmarkID))
    }

    private var enclosingTableView: NSTableView? {
        var view = superview
        while let currentView = view {
            if let tableView = currentView as? NSTableView {
                return tableView
            }
            view = currentView.superview
        }
        return nil
    }
}

private final class BookmarkRemoveCellView: NSTableCellView {
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private var row: Int?
    private var onRemove: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .smallSquare
        removeButton.isBordered = false
        removeButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "Remove Bookmark"
        )
        removeButton.imagePosition = .imageOnly
        removeButton.target = self
        removeButton.action = #selector(handleRemoveButton(_:))
        removeButton.toolTip = "Remove Bookmark"

        addSubview(removeButton)
        NSLayoutConstraint.activate([
            removeButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(row: Int, onRemove: @escaping (Int) -> Void) {
        self.row = row
        self.onRemove = onRemove
    }

    @objc
    private func handleRemoveButton(_ sender: Any?) {
        _ = sender
        guard let row else { return }
        onRemove?(row)
    }
}

private final class BookmarkThumbnailPickerSheetController: NSWindowController, NSWindowDelegate {
    let bookmarkID: BookmarkID

    var onSave: ((BookmarkID, PlaybackSeconds, PlaybackSeconds) -> Void)?
    var onClose: ((BookmarkThumbnailPickerSheetController) -> Void)?

    private let engine = PlaybackEngine()
    private let originalBookmarkTimeSeconds: PlaybackSeconds
    private let videoURL: URL
    private var durationSeconds: PlaybackSeconds = 0

    private let instructionLabel = NSTextField(labelWithString: "Pick a frame from the same video to use as this bookmark thumbnail.")
    private let playerView = AVPlayerView(frame: .zero)
    private let candidateTimeLabel = NSTextField(labelWithString: "")
    private let playPauseButton = NSButton(title: "", target: nil, action: nil)
    private let slider = BookmarkPickerScrubSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let decrementLargeButton = NSButton(title: "-1s", target: nil, action: nil)
    private let decrementSmallButton = NSButton(title: "-0.1s", target: nil, action: nil)
    private let incrementSmallButton = NSButton(title: "+0.1s", target: nil, action: nil)
    private let incrementLargeButton = NSButton(title: "+1s", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var candidateTimeSeconds: PlaybackSeconds
    private var hasClosed = false
    private var durationLoadTask: Task<Void, Never>?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false

    init(bookmark: Bookmark) {
        self.bookmarkID = bookmark.id
        self.originalBookmarkTimeSeconds = bookmark.timeSeconds
        self.videoURL = bookmark.videoURL
        self.candidateTimeSeconds = bookmark.effectiveThumbnailTimeSeconds

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Select Thumbnail Frame"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        bindEngine()
        configureUI()
        updateDisplayedCandidateTime()
        loadDuration()
        engine.attach(to: videoURL, autoplay: false)
        engine.seekTo(seconds: candidateTimeSeconds)
        updatePlayPauseButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        durationLoadTask?.cancel()
        engine.pause()
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        notifyClosedIfNeeded()
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14

        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.maximumNumberOfLines = 0

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.player = engine.currentPlayer()
        playerView.controlsStyle = .none
        playerView.showsSharingServiceButton = false
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = 10
        playerView.layer?.masksToBounds = true

        candidateTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateTimeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.bezelStyle = .rounded
        playPauseButton.target = self
        playPauseButton.action = #selector(handlePlayPause(_:))

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.target = self
        slider.action = #selector(handleSliderChanged(_:))
        slider.isContinuous = true
        slider.minValue = 0
        slider.maxValue = max(durationSeconds, max(candidateTimeSeconds, originalBookmarkTimeSeconds), 1)
        slider.doubleValue = candidateTimeSeconds
        slider.isEnabled = slider.maxValue > 0
        slider.onScrubBegan = { [weak self] in
            self?.beginScrubbing()
        }
        slider.onScrubEnded = { [weak self] seconds in
            self?.endScrubbing(at: seconds)
        }

        for button in [decrementLargeButton, decrementSmallButton, incrementSmallButton, incrementLargeButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.target = self
        }
        decrementLargeButton.action = #selector(handleDecrementLarge(_:))
        decrementSmallButton.action = #selector(handleDecrementSmall(_:))
        incrementSmallButton.action = #selector(handleIncrementSmall(_:))
        incrementLargeButton.action = #selector(handleIncrementLarge(_:))

        let stepButtonsRow = NSStackView(views: [
            playPauseButton,
            decrementLargeButton,
            decrementSmallButton,
            incrementSmallButton,
            incrementLargeButton
        ])
        stepButtonsRow.translatesAutoresizingMaskIntoConstraints = false
        stepButtonsRow.orientation = .horizontal
        stepButtonsRow.alignment = .centerY
        stepButtonsRow.spacing = 8

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel(_:))

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(handleSave(_:))

        let actionsRow = NSStackView(views: [cancelButton, saveButton])
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 10

        rootStack.addArrangedSubview(instructionLabel)
        rootStack.addArrangedSubview(playerView)
        rootStack.addArrangedSubview(candidateTimeLabel)
        rootStack.addArrangedSubview(slider)
        rootStack.addArrangedSubview(stepButtonsRow)
        rootStack.addArrangedSubview(actionsRow)

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            playerView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            playerView.heightAnchor.constraint(equalToConstant: 320),

            slider.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            instructionLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    private func bindEngine() {
        engine.onPositionUpdate = { [weak self] position in
            guard let self else { return }
            if abs(position.duration - self.durationSeconds) > 0.01 {
                self.durationSeconds = position.duration
                self.slider.maxValue = max(position.duration, max(self.candidateTimeSeconds, self.originalBookmarkTimeSeconds), 1)
                self.slider.isEnabled = self.slider.maxValue > 0
            }
            self.candidateTimeSeconds = position.seconds
            self.slider.doubleValue = position.seconds
            self.updateDisplayedCandidateTime()
            self.updatePlayPauseButton()
        }
    }

    @objc
    private func handleSliderChanged(_ sender: NSSlider) {
        candidateTimeSeconds = clampedTime(sender.doubleValue)
        updateDisplayedCandidateTime()
        if isScrubbing {
            engine.scrub(to: candidateTimeSeconds)
        } else {
            engine.seekTo(seconds: candidateTimeSeconds)
        }
    }

    @objc
    private func handleDecrementLarge(_ sender: Any?) {
        _ = sender
        nudgeCandidateTime(by: -1)
    }

    @objc
    private func handleDecrementSmall(_ sender: Any?) {
        _ = sender
        nudgeCandidateTime(by: -0.1)
    }

    @objc
    private func handleIncrementSmall(_ sender: Any?) {
        _ = sender
        nudgeCandidateTime(by: 0.1)
    }

    @objc
    private func handleIncrementLarge(_ sender: Any?) {
        _ = sender
        nudgeCandidateTime(by: 1)
    }

    @objc
    private func handleCancel(_ sender: Any?) {
        _ = sender
        closeSheet()
    }

    @objc
    private func handleSave(_ sender: Any?) {
        _ = sender
        onSave?(bookmarkID, candidateTimeSeconds, originalBookmarkTimeSeconds)
        closeSheet()
    }

    @objc
    private func handlePlayPause(_ sender: Any?) {
        _ = sender
        engine.togglePlayPause()
        updatePlayPauseButton()
    }

    func cancelAndClose() {
        closeSheet()
    }

    private func nudgeCandidateTime(by deltaSeconds: PlaybackSeconds) {
        candidateTimeSeconds = clampedTime(candidateTimeSeconds + deltaSeconds)
        slider.doubleValue = candidateTimeSeconds
        updateDisplayedCandidateTime()
        engine.seekTo(seconds: candidateTimeSeconds)
    }

    private func clampedTime(_ rawTime: PlaybackSeconds) -> PlaybackSeconds {
        let upperBound = max(durationSeconds, max(originalBookmarkTimeSeconds, candidateTimeSeconds), 0)
        guard upperBound > 0 else {
            return max(rawTime, 0)
        }
        return min(max(rawTime, 0), upperBound)
    }

    private func updateDisplayedCandidateTime() {
        let current = Self.displayTimestamp(for: candidateTimeSeconds)
        if durationSeconds > 0 {
            candidateTimeLabel.stringValue = "Frame time: \(current) / \(Self.displayTimestamp(for: durationSeconds))"
        } else {
            candidateTimeLabel.stringValue = "Frame time: \(current)"
        }
    }

    private func loadDuration() {
        durationLoadTask?.cancel()
        let videoURL = self.videoURL
        durationLoadTask = Task { [weak self] in
            let asset = AVURLAsset(url: videoURL)
            let duration: PlaybackSeconds
            do {
                let loadedDuration = try await asset.load(.duration)
                let loadedSeconds = loadedDuration.seconds
                duration = loadedSeconds.isFinite && loadedSeconds > 0 ? loadedSeconds : 0
            } catch {
                duration = 0
            }

            await MainActor.run {
                guard let self else { return }
                self.durationSeconds = duration
                self.slider.maxValue = max(duration, max(self.candidateTimeSeconds, self.originalBookmarkTimeSeconds), 1)
                self.slider.isEnabled = self.slider.maxValue > 0
                self.updateDisplayedCandidateTime()
            }
        }
    }

    private func closeSheet() {
        durationLoadTask?.cancel()
        engine.pause()
        engine.currentPlayer().replaceCurrentItem(with: nil)
        guard let window else {
            notifyClosedIfNeeded()
            return
        }

        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.close()
        }

        notifyClosedIfNeeded()
    }

    private func notifyClosedIfNeeded() {
        guard !hasClosed else {
            return
        }
        hasClosed = true
        onClose?(self)
    }

    private func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = engine.currentPlayer().rate != 0
        if wasPlayingBeforeScrub {
            engine.pause()
        }
        engine.beginScrubbing()
    }

    private func endScrubbing(at seconds: PlaybackSeconds) {
        guard isScrubbing else {
            engine.seekTo(seconds: clampedTime(seconds))
            return
        }
        candidateTimeSeconds = clampedTime(seconds)
        slider.doubleValue = candidateTimeSeconds
        engine.endScrubbing(at: candidateTimeSeconds)
        if wasPlayingBeforeScrub {
            engine.play()
        }
        wasPlayingBeforeScrub = false
        isScrubbing = false
        updatePlayPauseButton()
    }

    private func updatePlayPauseButton() {
        let symbolName = engine.currentPlayer().rate == 0 ? "play.fill" : "pause.fill"
        playPauseButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Play Pause"
        )
        playPauseButton.imagePosition = .imageOnly
    }

    private static func displayTimestamp(for seconds: PlaybackSeconds) -> String {
        let clampedSeconds = max(seconds, 0)
        return "\(BookmarkStore.formattedTimestamp(clampedSeconds)) (\(String(format: "%.2fs", clampedSeconds)))"
    }
}

private final class BookmarkPickerScrubSlider: NSSlider {
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: ((PlaybackSeconds) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onScrubBegan?()
        super.mouseDown(with: event)
        onScrubEnded?(doubleValue)
    }
}

private final class BookmarkTagsTextField: NSTextField {
    var bookmarkID: BookmarkID?
    var onInteraction: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        if let tableView = enclosingTableView {
            let row = tableView.row(for: self)
            if row >= 0, !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Ensure right-click menus show Paste/Copy for this text field.
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }

    private var enclosingTableView: NSTableView? {
        var view = superview
        while let currentView = view {
            if let tableView = currentView as? NSTableView {
                return tableView
            }
            view = currentView.superview
        }
        return nil
    }
}

private final class BookmarkDropView: NSView {
    var onFileURLsDropped: (([URL]) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFileURLsDropped?(urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            guard let url = object as? URL else { return nil }
            return url.isFileURL ? url : nil
        }
    }
}
