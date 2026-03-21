import Cocoa

final class KeyCaptureView: NSView {
    var keyHandler: ((NSEvent) -> Void)?
    var onFileURLsDropped: (([URL]) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        registerForDraggedTypes([.fileURL])
    }

    override func keyDown(with event: NSEvent) {
        keyHandler?(event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // No visual state; accept/drop is handled purely via return values.
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hasFileURLDrop(sender) else { return false }
        let urls = fileURLs(from: sender.draggingPasteboard)
        onFileURLsDropped?(urls)
        return true
    }

    private func hasFileURLDrop(_ sender: NSDraggingInfo) -> Bool {
        return !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { obj in
            guard let url = obj as? URL else { return nil }
            return url.isFileURL ? url : nil
        }
    }
}
