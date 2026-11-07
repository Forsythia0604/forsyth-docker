import Foundation

enum AppPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case pinned, group, running, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pinned: "固定在 Dock"
        case .group: "放入叠放"
        case .running: "仅运行时显示"
        case .hidden: "运行但隐藏"
        }
    }
}

struct StackConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var topApplicationID: String?
    init(id: String = UUID().uuidString, name: String, symbol: String = "square.stack.3d.up", topApplicationID: String? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.topApplicationID = topApplicationID
    }
}

struct ApplicationRule: Codable, Equatable, Sendable {
    var name: String = ""
    var path: String? = nil
    var placement: AppPlacement = .running
    var groupID: String? = nil
    var keepOnQuit: Bool = false
    var displayUUID: String? = nil
    var previousPlacement: AppPlacement? = nil
    var previousGroupID: String? = nil

    mutating func setHidden(_ hidden: Bool, validGroups: Set<String>) {
        if hidden, placement != .hidden {
            previousPlacement = placement; previousGroupID = groupID
            placement = .hidden; groupID = nil
        } else if !hidden, placement == .hidden {
            placement = previousPlacement ?? .running
            groupID = placement == .group ? previousGroupID : nil
            if placement == .hidden || (placement == .group && !validGroups.contains(groupID ?? "")) {
                placement = .running; groupID = nil
            }
            previousPlacement = nil; previousGroupID = nil
        }
    }
}

enum DisplayPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed, pointer, window, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: "固定在指定显示器"
        case .pointer: "跟随鼠标所在显示器"
        case .window: "跟随当前应用窗口"
        case .app: "按应用规则选择"
        }
    }
}

struct DockerConfiguration: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var groups: [StackConfiguration] = [
        .init(id: "browsers", name: "浏览器", symbol: "globe"),
        .init(id: "communications", name: "通讯与待办", symbol: "bubble.left.and.bubble.right"),
        .init(id: "ai", name: "AI", symbol: "sparkles")
    ]
    var rules: [String: ApplicationRule] = [:]
    var applicationOrder: [String] = []
    var dockVisible = true
    var nativeDockHidden = true
    var avoidanceEnabled = true
    var iconSize: Double = 81
    var showApplicationLibrary = true
    var glassStyle = "regular"
    var glassTransparency: Double = 0.65
    var showRunningIndicators = true
    var showBadges = true
    var stackStyle = "fan"
    var displayPolicy: DisplayPolicy = .fixed
    var homeDisplayUUID: String? = nil
    var arrangementHomes: [String: String] = [:]
    var pointerFollowDelay: Double = 0.7
    var meetingMode = false
    var hideForMeetingApps = false
    var meetingBundleIDs: [String] = ["us.zoom.xos", "com.tencent.meeting", "com.microsoft.teams2"]
    var clearRecentsOnQuit = true
    var appearance = "system"
    var mainShortcutEnabled = true
    var shortcutKeyCode: UInt32 = 2
    var shortcutModifiers: UInt32 = 0x1900 // Control + Option + Command

    static let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "local.codex.native-dock-preview",
        "local.codex.dock-window-helper", "local.codex.dock-window-helper.testing", "dev.yihui.docklock",
        "com.apple.apps.launcher", "com.apple.launchpad.launcher",
        "local.forsyth.docker.controlhost", "local.forsyth.docker.controlhost.testing",
        "local.forsyth.docker.preview.controlhost"
    ]

    static func initial() -> Self {
        var value = Self()
        let entries: [(String, String, String)] = [
            ("com.apple.Safari", "Safari", "browsers"),
            ("com.google.Chrome", "Google Chrome", "browsers"),
            ("com.tencent.xinWeChat", "微信", "communications"),
            ("com.microsoft.Outlook", "Outlook", "communications"),
            ("com.TickTick.task.mac", "滴答清单", "communications"),
            ("com.openai.codex", "ChatGPT", "ai"),
            ("com.deepseek.dsh", "DeepSeek Harness", "ai")
        ]
        let keep: Set<String> = ["com.tencent.xinWeChat", "com.microsoft.Outlook", "com.openai.codex", "com.deepseek.dsh"]
        for (id, name, group) in entries {
            value.rules[id] = ApplicationRule(name: name, placement: .group, groupID: group, keepOnQuit: keep.contains(id))
        }
        value.rules["com.ugee.PenTablet"] = ApplicationRule(name: "XPPen", placement: .hidden, keepOnQuit: true)
        return value
    }

    func orderedMemberIDs(in groupID: String) -> [String] {
        let positions = Dictionary(uniqueKeysWithValues: applicationOrder.enumerated().map { ($0.element, $0.offset) })
        return rules.keys.filter { rules[$0]?.placement == .group && rules[$0]?.groupID == groupID }.sorted { a, b in
            let ai = positions[a] ?? Int.max, bi = positions[b] ?? Int.max
            return ai == bi ? a < b : ai < bi
        }
    }

    mutating func replaceGroupMembers(_ memberIDs: [String], in groupID: String) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        var seen = Set<String>()
        let members = memberIDs.filter { !$0.isEmpty && !Self.protectedIDs.contains($0) && seen.insert($0).inserted }
        let selected = Set(members)
        for id in orderedMemberIDs(in: groupID) where !selected.contains(id) {
            rules[id]?.placement = .running
            rules[id]?.groupID = nil
        }
        for id in members {
            var rule = rules[id] ?? ApplicationRule()
            rule.placement = .group; rule.groupID = groupID
            rule.previousPlacement = nil; rule.previousGroupID = nil
            rules[id] = rule
        }
        // Reuse member slots so other stacks and standalone icons keep their order.
        var remaining = members.makeIterator()
        applicationOrder = applicationOrder.compactMap { id in
            selected.contains(id) ? remaining.next() : id
        }
        applicationOrder.append(contentsOf: remaining)
        normalize()
    }

    mutating func normalize() {
        showApplicationLibrary = true
        var seen = Set<String>()
        groups = groups.filter {
            !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.map {
            var group = $0
            group.name = String(group.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return group
        }
        let groupIDs = Set(groups.map(\.id))
        for id in Array(rules.keys) {
            guard var rule = rules[id] else { continue }
            if rule.placement == .group && !groupIDs.contains(rule.groupID ?? "") {
                rule.placement = .running
                rule.groupID = nil
            }
            if rule.placement != .group { rule.groupID = nil }
            if Self.protectedIDs.contains(id) {
                rule.keepOnQuit = true
                rule.placement = id == "com.apple.finder" ? .pinned : .hidden
                rule.groupID = nil
            }
            rules[id] = rule
        }
        for index in groups.indices {
            if let top = groups[index].topApplicationID,
               rules[top]?.placement != .group || rules[top]?.groupID != groups[index].id {
                groups[index].topApplicationID = nil
            }
        }
        seen.removeAll()
        applicationOrder = applicationOrder.filter { seen.insert($0).inserted }
        iconSize = iconSize.isFinite ? min(112, max(40, iconSize)) : 81
        glassTransparency = glassTransparency.isFinite ? min(1, max(0, glassTransparency)) : 0.65
        if !["regular", "clear"].contains(glassStyle) { glassStyle = "regular" }
        pointerFollowDelay = pointerFollowDelay.isFinite ? min(3, max(0.25, pointerFollowDelay)) : 0.7
        if !["fan", "grid"].contains(stackStyle) { stackStyle = "fan" }
        if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        if shortcutModifiers == 0x1B00 { shortcutModifiers = 0x1900 }
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        guard data.count <= 4_194_304 else { throw ConfigurationError.tooLarge }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = raw?["schemaVersion"] as? Int, version == 1 else { throw ConfigurationError.version }
        // Merge missing fields with this release's defaults for forward-compatible imports.
        let encoder = JSONEncoder()
        let defaults = try JSONSerialization.jsonObject(with: encoder.encode(initial())) as! [String: Any]
        var merged = defaults
        raw?.forEach { merged[$0.key] = $0.value }
        var result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: merged))
        result.normalize()
        return result
    }
}

enum ConfigurationError: LocalizedError {
    case version, tooLarge
    var errorDescription: String? {
        switch self {
        case .version: "配置版本不受支持，未更改当前配置。"
        case .tooLarge: "配置文件超过 4 MB，未导入。"
        }
    }
}

struct CatalogApplication: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    var installed: Bool = true
}

enum PlacementResolver {
    static let libraryID = "com.apple.apps.launcher"

    static func menuCopyIDs(configuration: DockerConfiguration, running: Set<String>, available: Set<String>) -> [String] {
        let standalone = standaloneIDs(configuration: configuration, running: running, available: available)
        let grouped = configuration.groups.flatMap { configuration.orderedMemberIDs(in: $0.id) }
        var seen = Set<String>()
        return (standalone + grouped).filter {
            ($0 == "com.apple.finder" || !DockerConfiguration.protectedIDs.contains($0)) && seen.insert($0).inserted
        }
    }

    static func dockSlotIDs(configuration: DockerConfiguration, standaloneIDs: [String]) -> [String] {
        var slots = standaloneIDs
        slots.removeAll { $0 == libraryID }
        slots.insert(libraryID, at: min(1, slots.count))
        return slots
    }

    static func coverIDs(memberIDs: [String], topApplicationID: String?) -> [String] {
        guard let topApplicationID, memberIDs.contains(topApplicationID) else { return memberIDs }
        return [topApplicationID] + memberIDs.filter { $0 != topApplicationID }
    }

    static func standaloneIDs(configuration: DockerConfiguration, running: Set<String>, available: Set<String>) -> [String] {
        let eligible = available.filter { id in
            guard id != "com.apple.finder", !DockerConfiguration.protectedIDs.contains(id) else { return false }
            let mode = configuration.rules[id]?.placement ?? .running
            return mode == .pinned || (mode == .running && running.contains(id))
        }
        let sorted = eligible.sorted { a, b in
            let ai = configuration.applicationOrder.firstIndex(of: a) ?? Int.max
            let bi = configuration.applicationOrder.firstIndex(of: b) ?? Int.max
            return ai == bi ? a < b : ai < bi
        }
        return ["com.apple.finder"] + sorted
    }
    static func quitTargets(regularIDs: Set<String>, rules: [String: ApplicationRule], ownID: String) -> Set<String> {
        regularIDs.filter {
            $0 != ownID && !DockerConfiguration.protectedIDs.contains($0) && !(rules[$0]?.keepOnQuit ?? false)
        }
    }
}
