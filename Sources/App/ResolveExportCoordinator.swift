import AppKit
import UniformTypeIdentifiers

enum ResolveExportCoordinator {
    static func presentSavePanel(
        for result: ResolveExportBuildResult,
        suggestingName: String = "QuickPreview Export",
        window: NSWindow?
    ) {
        guard !result.items.isEmpty else {
            presentAlert(
                title: "Nothing to Export",
                message: skipMessage(
                    prefix: "No clips could be exported.",
                    skippedPaths: result.skippedPaths
                ),
                window: window
            )
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestingName.hasSuffix(".fcpxml")
            ? suggestingName
            : "\(suggestingName).fcpxml"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        } else {
            panel.allowedFileTypes = ["fcpxml"]
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            let projectName = url.deletingPathExtension().lastPathComponent
            do {
                try FCPXMLExporter.write(items: result.items, projectName: projectName, to: url)
                presentAlert(
                    title: "Exported to Resolve",
                    message: completionMessage(result: result, url: url),
                    window: window
                )
            } catch ResolveExportError.noExportableClips {
                presentAlert(
                    title: "Nothing to Export",
                    message: "No clips could be exported.",
                    window: window
                )
            } catch ResolveExportError.writeFailed(let detail) {
                presentAlert(
                    title: "Export Failed",
                    message: detail,
                    window: window
                )
            } catch {
                presentAlert(
                    title: "Export Failed",
                    message: error.localizedDescription,
                    window: window
                )
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func completionMessage(result: ResolveExportBuildResult, url: URL) -> String {
        var lines: [String] = [
            "Saved \(result.items.count) clip\(result.items.count == 1 ? "" : "s") to:",
            url.path,
            "",
            "In DaVinci Resolve: File → Import → Timeline… (or drag the .fcpxml onto Resolve)."
        ]
        if !result.skippedPaths.isEmpty {
            lines.append("")
            lines.append(skipMessage(prefix: "Skipped \(result.skippedPaths.count) file(s):", skippedPaths: result.skippedPaths))
        }
        if result.usedFallbackFrameRate {
            lines.append("")
            lines.append("Some clips used a fallback frame rate of \(Int(ResolveExportBuilder.fallbackFrameRate)) fps.")
        }
        return lines.joined(separator: "\n")
    }

    private static func skipMessage(prefix: String, skippedPaths: [String]) -> String {
        guard !skippedPaths.isEmpty else {
            return prefix
        }
        let names = skippedPaths.prefix(8).map { ($0 as NSString).lastPathComponent }
        var message = "\(prefix)\n" + names.map { "• \($0)" }.joined(separator: "\n")
        if skippedPaths.count > names.count {
            message += "\n• …and \(skippedPaths.count - names.count) more"
        }
        return message
    }

    private static func presentAlert(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }
}
