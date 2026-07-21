import Foundation

enum FCPXMLExporter {
    static func exportXML(
        items: [ResolveExportItem],
        projectName: String
    ) throws -> String {
        guard !items.isEmpty else {
            throw ResolveExportError.noExportableClips
        }

        let safeProjectName = sanitizeName(projectName.isEmpty ? "QuickPreview Export" : projectName)
        let sequenceDuration = items.reduce(0.0) { $0 + $1.clipDuration }
        let primary = items[0]
        let formatID = "r1"
        let frameDuration = frameDurationString(for: primary.frameRate)

        var resources: [String] = []
        resources.append(
            """
            <format id="\(formatID)" name="FFVideoFormat\(primary.height)p\(Int(primary.frameRate.rounded()))" frameDuration="\(frameDuration)" width="\(primary.width)" height="\(primary.height)"/>
            """
        )

        var assetIDByPath: [String: String] = [:]
        var nextAssetIndex = 2
        for item in items {
            let key = item.videoURL.path
            if assetIDByPath[key] != nil {
                continue
            }
            let assetID = "r\(nextAssetIndex)"
            nextAssetIndex += 1
            assetIDByPath[key] = assetID
            let src = xmlEscape(item.videoURL.absoluteString)
            let name = xmlEscape((item.videoPath as NSString).lastPathComponent)
            resources.append(
                """
                <asset id="\(assetID)" name="\(name)" src="\(src)" start="0s" duration="\(timeString(item.durationSeconds))" hasVideo="1" hasAudio="1" format="\(formatID)"/>
                """
            )
        }

        var spineClips: [String] = []
        var timelineOffset: PlaybackSeconds = 0
        for item in items {
            let assetID = assetIDByPath[item.videoURL.path] ?? "r2"
            let markerXML = item.markers.map { marker in
                let noteAttr: String
                if let note = marker.note, !note.isEmpty {
                    noteAttr = " note=\"\(xmlEscape(note))\""
                } else {
                    noteAttr = ""
                }
                return """
                <marker start="\(timeString(marker.timeSeconds))" duration="\(frameDuration)" value="\(xmlEscape(marker.name))"\(noteAttr)/>
                """
            }.joined(separator: "\n")

            let indentedMarkers = markerXML
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "                            \($0)" }
                .joined(separator: "\n")

            let clipBody: String
            if markerXML.isEmpty {
                clipBody = ""
            } else {
                clipBody = "\n\(indentedMarkers)\n                        "
            }

            spineClips.append(
                """
                                        <asset-clip name="\(xmlEscape(item.clipName))" ref="\(assetID)" offset="\(timeString(timelineOffset))" start="\(timeString(item.clipStart))" duration="\(timeString(item.clipDuration))" tcFormat="NDF">\(clipBody)</asset-clip>
                """
            )
            timelineOffset += item.clipDuration
        }

        let resourcesBlock = resources.map { "            \($0)" }.joined(separator: "\n")
        let spineBlock = spineClips.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
            <resources>
        \(resourcesBlock)
            </resources>
            <library>
                <event name="\(xmlEscape(safeProjectName))">
                    <project name="\(xmlEscape(safeProjectName))">
                        <sequence format="\(formatID)" duration="\(timeString(sequenceDuration))" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                            <spine>
        \(spineBlock)
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
    }

    static func write(
        items: [ResolveExportItem],
        projectName: String,
        to url: URL
    ) throws {
        let xml = try exportXML(items: items, projectName: projectName)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ResolveExportError.writeFailed(error.localizedDescription)
        }
    }

    static func timeString(_ seconds: PlaybackSeconds) -> String {
        if seconds == 0 {
            return "0s"
        }
        // Keep enough precision for sub-frame accuracy without scientific notation.
        var value = String(format: "%.6f", seconds)
        while value.hasSuffix("0") {
            value.removeLast()
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return "\(value)s"
    }

    static func frameDurationString(for frameRate: Double) -> String {
        if abs(frameRate - 29.97) < 0.02 || abs(frameRate - 29.970) < 0.02 {
            return "1001/30000s"
        }
        if abs(frameRate - 23.976) < 0.02 {
            return "1001/24000s"
        }
        if abs(frameRate - 59.94) < 0.02 {
            return "1001/60000s"
        }
        let rounded = Int(frameRate.rounded())
        let fps = max(rounded, 1)
        return "1/\(fps)s"
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func sanitizeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "QuickPreview Export" : trimmed
    }
}
