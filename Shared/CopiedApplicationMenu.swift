import Foundation

struct CopiedMenuStep: Codable, Hashable, Sendable {
    let title: String
    let identifier: String?

    /// Refuse stale or ambiguous matches instead of falling back to a row number.
    func uniqueIndex(in candidates: [CopiedMenuStep]) -> Int? {
        let matches = candidates.indices.filter { index in
            let value = candidates[index]
            return value.title == title && (identifier == nil || value.identifier == identifier)
        }
        return matches.count == 1 ? matches.first : nil
    }
}

struct CopiedMenuItem: Codable, Identifiable, Sendable {
    let title: String
    let path: [CopiedMenuStep]
    let enabled: Bool
    let checked: Bool
    let children: [CopiedMenuItem]
    var id: String { path.map { $0.title + "\u{1F}" + ($0.identifier ?? "") }.joined(separator: "\u{1E}") }
    var commandCount: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.commandCount } }
}

enum CopiedMenuSource: String, Codable, Sendable {
    case nativeDock, applicationMenu
    var title: String { self == .nativeDock ? "原生 Dock" : "应用菜单栏" }
}

struct CopiedApplicationMenu: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let applicationPath: String
    let source: CopiedMenuSource
    let capturedAt: Date
    let items: [CopiedMenuItem]
    var enabled = true
    var commandCount: Int { items.reduce(0) { $0 + $1.commandCount } }
}

struct MenuCopyReport: Codable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case copied, partial, unavailable
        var title: String {
            switch self {
            case .copied: return "已复制"
            case .partial: return "部分复制"
            case .unavailable: return "无法复制"
            }
        }
    }
    let id: String
    let name: String
    let date: Date
    let outcome: Outcome
    let source: CopiedMenuSource?
    let commandCount: Int
    let detail: String
}

struct MenuCopyArchive: Codable, Sendable {
    var schemaVersion = 1
    var menus: [String: CopiedApplicationMenu] = [:]
    var reports: [String: MenuCopyReport] = [:]
    var liveWindowsEnabled: Bool? = true
}

struct LiveMenuTab: Identifiable, Sendable {
    let id: String
    let title: String
    let selected: Bool
}

struct LiveMenuWindow: Identifiable, Sendable {
    let id: String
    let title: String
    let minimized: Bool
    let tabs: [LiveMenuTab]
}

struct LiveMenuSnapshot: Sendable {
    let windows: [LiveMenuWindow]
    let complete: Bool
    let tabsComplete: Bool
    let available: Bool
    let detail: String
    var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }
}
