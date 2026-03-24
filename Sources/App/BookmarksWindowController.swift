import Cocoa

final class BookmarksWindowController: NSWindowController, NSWindowDelegate {
    private enum ColumnIdentifier {
        static let thumbnail = NSUserInterfaceItemIdentifier("thumbnail")
        static let time = NSUserInterfaceItemIdentifier("time")
        static let filename = NSUserInterfaceItemIdentifier("filename")
        static let tags = NSUserInterfaceItemIdentifier("tags")
        static let remove = NSUserInterfaceItemIdentifier("remove")
    }

    private let bookmarkStore: BookmarkStore
    private let thumbnailService: VideoThumbnailService
    private let searchField = NSSearchField(frame: .zero)
    private let scopeControl = NSSegmentedControl(labels: ["Current Video", "All Videos"], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = BookmarkTableView(frame: .zero)
    private let emptyStateLabel = NSTextField(labelWithString: "No bookmarks yet.")
    private var bookmarkChangeObserver: NSObjectProtocol?
    private var bookmarks: [Bookmark] = []
    private var currentVideoURL: URL?
    private var currentScope: BookmarkListScope = .currentVideo
    private var suppressBookmarkOpenOnSelectionChange = false

    var onOpenBookmark: ((Bookmark) -> Void)?

    init(bookmarkStore: BookmarkStore, thumbnailService: VideoThumbnailService) {
        self.bookmarkStore = bookmarkStore
        self.thumbnailService = thumbnailService
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookmarks"
        window.minSize = NSSize(width: 660, height: 420)
        super.init(window: window)
        window.delegate = self
        configureUI()
        installObservers()
        reloadBookmarks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let bookmarkChangeObserver {
            NotificationCenter.default.removeObserver(bookmarkChangeObserver)
        }
    }

    func setCurrentVideoURL(_ videoURL: URL?) {
        currentVideoURL = videoURL?.standardizedFileURL
        reloadBookmarks()
    }

    func revealBookmark(_ bookmark: Bookmark) {
        if bookmark.videoPath == currentVideoURL?.path {
            currentScope = .currentVideo
            scopeControl.selectedSegment = BookmarkListScope.currentVideo.rawValue
        } else {
            currentScope = .allVideos
            scopeControl.selectedSegment = BookmarkListScope.allVideos.rawValue
        }
        reloadBookmarks(selecting: bookmark.id)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        window?.makeFirstResponder(nil)
    }

    private func configureUI() {
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
        scopeControl.selectedSegment = BookmarkListScope.currentVideo.rawValue
        scopeControl.segmentStyle = .rounded

        controlsRow.addArrangedSubview(searchField)
        controlsRow.addArrangedSubview(scopeControl)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = NSTableHeaderView()
        tableView.allowsMultipleSelection = false
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
        timeColumn.resizingMask = .autoresizingMask

        let filenameColumn = NSTableColumn(identifier: ColumnIdentifier.filename)
        filenameColumn.title = "Filename"
        filenameColumn.minWidth = 180
        filenameColumn.width = 220
        filenameColumn.resizingMask = .autoresizingMask

        let tagsColumn = NSTableColumn(identifier: ColumnIdentifier.tags)
        tagsColumn.title = "Tags"
        tagsColumn.minWidth = 240
        tagsColumn.width = 300
        tagsColumn.resizingMask = .autoresizingMask

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
        tableView.addTableColumn(tagsColumn)
        tableView.addTableColumn(removeColumn)
        scrollView.documentView = tableView

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)

        contentView.addSubview(controlsRow)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            controlsRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            controlsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            controlsRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            scrollView.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20)
        ])
    }

    private func installObservers() {
        bookmarkChangeObserver = NotificationCenter.default.addObserver(
            forName: .bookmarkStoreDidChange,
            object: bookmarkStore,
            queue: .main
        ) { [weak self] _ in
            self?.reloadBookmarks()
        }
    }

    private func reloadBookmarks(selecting bookmarkID: BookmarkID? = nil) {
        let selectedBookmarkID: BookmarkID? = {
            guard tableView.selectedRow >= 0, tableView.selectedRow < bookmarks.count else {
                return bookmarkID
            }
            return bookmarkID ?? bookmarks[tableView.selectedRow].id
        }()

        bookmarks = bookmarkStore.bookmarks(
            scope: currentScope,
            currentVideoURL: currentVideoURL,
            searchQuery: searchField.stringValue
        )
        suppressBookmarkOpenOnSelectionChange = true
        tableView.reloadData()

        if let selectedBookmarkID,
           let row = bookmarks.firstIndex(where: { $0.id == selectedBookmarkID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        suppressBookmarkOpenOnSelectionChange = false

        updateEmptyState()
    }

    private func updateEmptyState() {
        let message: String
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
        }
        emptyStateLabel.stringValue = message
        let isEmpty = bookmarks.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.alphaValue = isEmpty ? 0.78 : 1
    }

    private func openSelectedBookmark() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < bookmarks.count else {
            return
        }
        onOpenBookmark?(bookmarks[tableView.selectedRow])
    }

    private func removeSelectedBookmark() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < bookmarks.count else {
            return
        }
        bookmarkStore.removeBookmark(id: bookmarks[tableView.selectedRow].id)
    }

    private func removeBookmark(at row: Int) {
        guard row >= 0, row < bookmarks.count else {
            return
        }
        bookmarkStore.removeBookmark(id: bookmarks[row].id)
    }

    @objc
    private func handleScopeChanged(_ sender: NSSegmentedControl) {
        currentScope = BookmarkListScope(rawValue: sender.selectedSegment) ?? .currentVideo
        reloadBookmarks()
    }

    @objc
    private func handleTableAction(_ sender: Any?) {
        _ = sender
        let clickedColumn = tableView.clickedColumn
        let tagsColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.tags)
        let removeColumnIndex = tableView.column(withIdentifier: ColumnIdentifier.remove)
        if clickedColumn == tagsColumnIndex || clickedColumn == removeColumnIndex {
            return
        }
        openSelectedBookmark()
    }
}

extension BookmarksWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        _ = tableView
        return bookmarks.count
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
        case ColumnIdentifier.tags:
            let cell = reusableTagsCell(in: tableView)
            cell.configure(bookmark: bookmark, delegate: self)
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
        guard !suppressBookmarkOpenOnSelectionChange else {
            return
        }
        guard window?.firstResponder !== tableView.currentEditor() else {
            return
        }
        openSelectedBookmark()
    }

    private func reusableThumbnailCell(in tableView: NSTableView) -> BookmarkThumbnailCellView {
        let identifier = NSUserInterfaceItemIdentifier("BookmarkThumbnailCellView")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BookmarkThumbnailCellView {
            return cell
        }
        let cell = BookmarkThumbnailCellView(frame: .zero)
        cell.identifier = identifier
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

extension BookmarksWindowController: NSSearchFieldDelegate, NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else {
            return
        }
        reloadBookmarks()
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
}

private final class BookmarkThumbnailCellView: NSTableCellView {
    private let thumbnailImageView = NSImageView(frame: .zero)
    private let previewImageView = NSImageView(frame: .zero)
    private let previewPopover = NSPopover()
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

        let previewContainer = NSViewController()
        let previewContentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        previewContentView.wantsLayer = true
        previewContentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        previewContainer.view = previewContentView
        previewContentView.addSubview(previewImageView)
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: previewContentView.leadingAnchor, constant: 12),
            previewImageView.trailingAnchor.constraint(equalTo: previewContentView.trailingAnchor, constant: -12),
            previewImageView.topAnchor.constraint(equalTo: previewContentView.topAnchor, constant: 12),
            previewImageView.bottomAnchor.constraint(equalTo: previewContentView.bottomAnchor, constant: -12)
        ])
        previewPopover.contentViewController = previewContainer
        previewPopover.behavior = .semitransient
        previewPopover.animates = false

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
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
        isHovering = false
        previewPopover.close()
    }

    func configure(bookmark: Bookmark, thumbnailService: VideoThumbnailService) {
        bookmarkID = bookmark.id
        currentVideoURL = bookmark.videoURL
        currentTimeSeconds = bookmark.timeSeconds
        self.thumbnailService = thumbnailService
        hasLoadedHighResolutionPreview = false
        thumbnailImageView.image = Self.placeholderImage
        previewImageView.image = Self.placeholderImage
        previewPopover.close()
        thumbnailService.requestThumbnail(
            for: bookmark.videoURL,
            at: bookmark.timeSeconds,
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

    private func showPreviewIfNeeded() {
        guard let image = previewImageView.image else {
            return
        }
        updatePreviewSize(for: image)
        requestHighResolutionPreviewIfNeeded()
        guard window != nil else {
            return
        }
        if previewPopover.isShown {
            return
        }
        previewPopover.show(relativeTo: thumbnailImageView.bounds, of: thumbnailImageView, preferredEdge: .maxX)
    }

    private func updatePreviewSize(for image: NSImage) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            previewPopover.contentSize = NSSize(width: 480, height: 300)
            return
        }
        let maxContentWidth: CGFloat = 540
        let maxContentHeight: CGFloat = 360
        let widthScale = maxContentWidth / imageSize.width
        let heightScale = maxContentHeight / imageSize.height
        let scale = min(widthScale, heightScale, 1.8)
        let contentWidth = max(270, floor(imageSize.width * scale))
        let contentHeight = max(150, floor(imageSize.height * scale))
        previewPopover.contentSize = NSSize(width: contentWidth + 24, height: contentHeight + 24)
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

    func configure(bookmark: Bookmark, delegate: NSTextFieldDelegate) {
        tagsTextField.bookmarkID = bookmark.id
        tagsTextField.delegate = delegate
        tagsTextField.stringValue = BookmarkStore.tagString(from: bookmark.tags)
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
        removeButton.bezelStyle = .texturedRounded
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

private final class BookmarkTagsTextField: NSTextField {
    var bookmarkID: BookmarkID?
}
