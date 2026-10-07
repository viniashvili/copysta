import Foundation

enum EntryKind: String, Codable {
    case text
    case image
}

struct Entry: Identifiable {
    let id: Int64
    let kind: EntryKind
    let text: String?
    let imagePath: String?
    let hash: String
    let size: Int64
    let createdAt: Date
    let lastUsedAt: Date

    var textPreview: String {
        guard let t = text else { return "" }
        let collapsed = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let truncated = String(collapsed.prefix(100))
        return truncated.count < collapsed.count ? truncated + "…" : truncated
    }

    /// "Just now", "5 min ago", "Today, 09:12", "Yesterday, 18:04", "3 Oct, 18:04".
    var timeLabel: String {
        let d = Date().timeIntervalSince(lastUsedAt)
        if d < 60 { return "Just now" }
        if d < 3600 { return "\(Int(d / 60)) min ago" }

        let time = Self.timeFormatter.string(from: lastUsedAt)
        let cal = Calendar.current
        if cal.isDateInToday(lastUsedAt) { return "Today, \(time)" }
        if cal.isDateInYesterday(lastUsedAt) { return "Yesterday, \(time)" }
        return "\(Self.dayFormatter.string(from: lastUsedAt)), \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()
}

// Temporary item from clipboard before it is persisted.
struct ClipItem {
    let kind: EntryKind
    let text: String?
    let imageData: Data?
}
