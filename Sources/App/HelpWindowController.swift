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
            "Enable QuickPreview > Background Shortcut if you want the global shortcut to work after closing the app.",
            "Click the video or press Space to play/pause.",
            "Use Left/Right arrows for fine seek and Shift + arrows for coarse seek.",
            "Use Up/Down arrows for frame stepping."
        ]))

        stack.addArrangedSubview(makeSectionTitle("Precision Timeline & Looping"))
        stack.addArrangedSubview(makeBulletList([
            "Drag the left and right handles to define a loop range.",
            "Press L to toggle loop on/off for the current clip.",
            "Loop preference is remembered per clip.",
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
            ("Ctrl + Space", "Reopen QuickPreview from anywhere when Background Shortcut is enabled"),
            ("Space", "Play / Pause"),
            ("L", "Toggle loop on current clip"),
            ("R", "Rotate clockwise (0° / 90° / 180° / 270°)"),
            ("Left Arrow", "Seek backward (fine)"),
            ("Right Arrow", "Seek forward (fine)"),
            ("Shift + Left Arrow", "Seek backward (coarse)"),
            ("Shift + Right Arrow", "Seek forward (coarse)"),
            ("Down Arrow", "Step one frame backward"),
            ("Up Arrow", "Step one frame forward"),
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
