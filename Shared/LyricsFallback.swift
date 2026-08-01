import Foundation

/// Chooses useful text when a media file has no dedicated lyrics tag.
/// A clearly marked lyrics section wins; otherwise a cleaned description is
/// still better than hiding information that shipped with the user's file.
enum LyricsFallback {
    static func content(fromDescription rawValue: String) -> String? {
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)

        if let marker = lines.firstIndex(where: isLyricsMarker) {
            let section = clean(Array(lines.dropFirst(marker + 1)), stopAtPromotionalFooter: true)
            if isUseful(section) { return section }
        }

        let description = clean(lines, stopAtPromotionalFooter: false)
        return isUseful(description) ? description : nil
    }

    private static func isLyricsMarker(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains("lyrics video") && !value.contains("lyric video") else { return false }
        return value == "lyrics" || value.hasSuffix(" lyrics") || value.hasPrefix("lyrics:")
            || value.contains(" lyrics:")
    }

    private static func clean(_ source: [String], stopAtPromotionalFooter: Bool) -> String {
        var result: [String] = []
        var previousWasBlank = false

        for sourceLine in source {
            let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            let isFooter = line.hasPrefix("#") || lower.hasPrefix("subscribe")
                || lower.hasPrefix("follow ") || lower.hasPrefix("follow:")
                || lower.hasPrefix("listen ") || lower.hasPrefix("listen:")
                || lower.hasPrefix("stream ") || lower.hasPrefix("stream:")

            if stopAtPromotionalFooter, isFooter, result.filter({ !$0.isEmpty }).count >= 2 { break }
            if line.hasPrefix("http://") || line.hasPrefix("https://") || line.hasPrefix("www.") { continue }
            if line.hasPrefix("#") { continue }

            if line.isEmpty {
                if !result.isEmpty, !previousWasBlank { result.append("") }
                previousWasBlank = true
            } else {
                result.append(line)
                previousWasBlank = false
            }
        }

        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUseful(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0.isWhitespace })
        return value.count >= 24 && words.count >= 4
    }
}
