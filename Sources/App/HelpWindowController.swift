import Cocoa

final class HelpWindowController: NSWindowController {
    private static let infographicResourceName = "quickpreview-guide-infographic"

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickPreview Guide"
        window.minSize = NSSize(width: 700, height: 560)
        self.init(window: window)
        configureUI()
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView(frame: contentView.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = NSView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let titleLabel = makeTitleLabel("QuickPreview - How It Works")
        let introLabel = makeBodyLabel(
            """
            QuickPreview is a lightweight video utility for quick review loops. \
            Open a clip, mark a section, and repeatedly play that segment while keeping \
            your settings saved per clip.
            """
        )

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(introLabel)
        stack.addArrangedSubview(makeSectionDivider())
        stack.addArrangedSubview(makeSectionTitle("Getting Started"))
        stack.addArrangedSubview(makeBulletList([
            "Open a video from File > Open..., drag and drop, or use Finder selection.",
            "Use the Autoplay switch in the main window when you want newly opened clips and bookmarks to stay paused.",
            "Enable QuickPreview > Background Shortcut if you want the global shortcut to work after closing the app.",
            "Click the video or press Space to play/pause, even while the bookmark manager is focused.",
            "When you are editing the bookmark search or tags fields, Space stays in that text field instead.",
            "Use Left/Right arrows for fine seek and Shift + arrows for coarse seek.",
            "Use Up/Down arrows to move through bookmarks when the bookmark manager is open.",
            "Use Shift + Up/Down arrows for frame stepping."
        ]))

        stack.addArrangedSubview(makeSectionTitle("Precision Timeline & Looping"))
        stack.addArrangedSubview(makeBulletList([
            "Drag the left and right handles to define a loop range.",
            "Thin markers above the timeline show every saved bookmark for the current clip, including when you opened the clip from a bookmark.",
            "Click a bookmark marker once to select it, then drag it to retime that bookmark and refresh its saved thumbnail frame.",
            "Bookmark marker drags preview live in the player and save immediately when you release.",
            "Press L to toggle loop on/off for the current clip.",
            "Press Cmd + Shift + P to toggle autoplay for newly opened clips and bookmark jumps.",
            "Loop preference is remembered per clip.",
            "Autoplay preference is remembered across app launches.",
            "When enabled, QuickPreview loops the selected segment automatically."
        ]))

        stack.addArrangedSubview(makeSectionTitle("Rotation & Audio"))
        stack.addArrangedSubview(makeBulletList([
            "Press R to rotate clockwise through 0, 90, 180, and 270 degrees.",
            "Rotation is remembered per clip.",
            "Adjust volume boost up to 300% with the bottom slider.",
            "The current percentage and timeline position are shown on the right."
        ]))

        stack.addArrangedSubview(makeSectionTitle("Keyboard Shortcuts"))
        stack.addArrangedSubview(makeShortcutsTable())
        stack.addArrangedSubview(makeBodyLabel(
            "The background helper tries Ctrl + Space first. If macOS reserves it for input switching, QuickPreview falls back to Option + Space or Cmd + Shift + Space."
        ))

        if let infographicView = makeInfographicView() {
            stack.addArrangedSubview(makeSectionTitle("Feature Overview"))
            stack.addArrangedSubview(infographicView)
        }

        contentView.addSubview(scrollView)
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -48),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    private func makeTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textColor = .labelColor
        return label
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeBodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func makeBulletList(_ entries: [String]) -> NSTextField {
        let bulletText = entries.map { "• \($0)" }.joined(separator: "\n")
        let label = NSTextField(wrappingLabelWithString: bulletText)
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func makeSectionDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func makeShortcutsTable() -> NSView {
        let rows: [(shortcut: String, action: String)] = [
            ("Cmd + O", "Open video file"),
            ("Cmd + Shift + O", "Open current Finder selection"),
            ("Cmd + Shift + P", "Toggle autoplay for newly opened clips and bookmark jumps"),
            ("Ctrl + Space", "Reopen QuickPreview from anywhere when Background Shortcut is enabled"),
            ("Space", "Play / Pause, including from the bookmark manager unless a text field is being edited"),
            ("L", "Toggle loop on current clip"),
            ("R", "Rotate clockwise (0° / 90° / 180° / 270°)"),
            ("Left Arrow", "Seek backward (fine)"),
            ("Right Arrow", "Seek forward (fine)"),
            ("Shift + Left Arrow", "Seek backward (coarse)"),
            ("Shift + Right Arrow", "Seek forward (coarse)"),
            ("Option + Up Arrow", "Jump to the next bookmark on the current clip"),
            ("Option + Down Arrow", "Jump to the previous bookmark on the current clip"),
            ("Up / Down Arrow", "Move through bookmarks when the bookmark manager is open"),
            ("Shift + Down Arrow", "Step one frame backward"),
            ("Shift + Up Arrow", "Step one frame forward"),
            ("Esc", "Close preview window"),
            ("Cmd + Q", "Quit app")
        ]

        let gridRows: [[NSView]] = [[
            makeTableHeaderCell("Shortcut"),
            makeTableHeaderCell("Action")
        ]] + rows.map { row in
            [
                makeTableBodyCell(row.shortcut),
                makeTableBodyCell(row.action)
            ]
        }

        let grid = NSGridView(views: gridRows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.xPlacement = .leading
        grid.yPlacement = .center

        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 0).width = 220

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeTableHeaderCell(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeTableBodyCell(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeInfographicView() -> NSImageView? {
        guard
            let url = Bundle.main.url(
                forResource: Self.infographicResourceName,
                withExtension: "png"
            ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.widthAnchor.constraint(equalToConstant: 820).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 512).isActive = true
        return imageView
    }
}
