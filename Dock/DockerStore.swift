import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let dockerConfigurationChanged = Notification.Name("ForsythDockerConfigurationChanged")
}

@MainActor
final class DockerStore: ObservableObject, QuitServiceStore {
    static let shared = DockerStore()
    static let isPreview = CommandLine.arguments.contains("--preview") ||
        Bundle.main.object(forInfoDictionaryKey: "ForsythInterfacePreview") as? Bool == true
    var quitIsPreview: Bool { Self.isPreview }
    @Published private(set) var configuration: DockerConfiguration
    @Published private(set) var catalog: [CatalogApplication] = []
    @Published private(set) var runningIDs = Set<String>()
    @Published var selectedPage = "apps"
    @Published var message = ""
    @Published var nativeDockStatus = "正在连接 Dock 隐藏组件…"
    @Published var nativeDockEffective = false
    @Published var nativePermission = false
    @Published var helperStatus = "正在连接窗口助手…"
    @Published var helperTrusted = false
    @Published var screens: [String: String] = [:]
    @Published var scanning = false
    let directory: URL
    var configURL: URL { directory.appendingPathComponent("configuration.json") }
    var backupURL: URL { directory.appendingPathComponent("configuration.previous.json") }
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]

    private init() {
        if let index = CommandLine.arguments.firstIndex(of: "--profile"), CommandLine.arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DockerForsyth")
        }
        var loaded: DockerConfiguration?
        var loadingMessage: String?
        let url = directory.appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { loaded = try DockerConfiguration.decodeValidated(Data(contentsOf: url)) }
            catch {
                loadingMessage = "配置读取失败，已尝试恢复上一份备份：\(error.localizedDescription)"
                if let backup = try? Data(contentsOf: directory.appendingPathComponent("configuration.previous.json")) {
                    loaded = try? DockerConfiguration.decodeValidated(backup)
                }
            }
        }
        configuration = loaded ?? Self.migrateLegacy()
        configuration.normalize()
        message = loadingMessage ?? (loaded == nil ? "已导入现有叠放、固定应用和退出保留名单。" : "")
        if loaded == nil && !Self.isPreview { persist() }
        updateRunning()
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateRunning() }
            })
        }
        scanApplications()
    }

    private static func migrateLegacy() -> DockerConfiguration {
        var c = DockerConfiguration.initial()
        let defaults = UserDefaults(suiteName: "local.codex.native-dock-preview")
        c.iconSize = defaults?.object(forKey: "iconSize") as? Double ?? 81
        c.avoidanceEnabled = defaults?.object(forKey: "maximizeAboveDock") as? Bool ?? true
        c.applicationOrder = defaults?.stringArray(forKey: "visibleApplicationOrder") ?? []
        for item in defaults?.array(forKey: "pinnedApplications") as? [[String: String]] ?? [] {
            guard let id = item["id"] else { continue }
            var rule = c.rules[id] ?? ApplicationRule()
            rule.name = item["name"] ?? id
            rule.path = item["path"]
            rule.placement = .pinned; rule.groupID = nil
            c.rules[id] = rule
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/Applications/一键退出.app/Contents/document.wflow")),
           let workflow = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let actions = workflow["actions"] as? [[String: Any]] {
            for action in actions {
                guard let a = action["action"] as? [String: Any],
                      a["BundleIdentifier"] as? String == "com.apple.Automator.QuitAllApplications",
                      let parameters = a["ActionParameters"] as? [String: Any],
                      let paths = parameters["fileNames"] as? [String] else { continue }
                for path in paths {
                    guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { continue }
                    var rule = c.rules[id] ?? ApplicationRule(name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? id)
                    rule.path = path; rule.keepOnQuit = true; c.rules[id] = rule
                }
            }
        }
        return c
    }

    func change(_ mutation: (inout DockerConfiguration) -> Void) {
        var next = configuration
        mutation(&next); next.normalize()
        guard next != configuration else { return }
        configuration = next
        if !Self.isPreview { persist() }
        NotificationCenter.default.post(name: .dockerConfigurationChanged, object: self)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            if let prior = try? Data(contentsOf: configURL) {
                if (try? DockerConfiguration.decodeValidated(prior)) != nil {
                    try prior.write(to: backupURL, options: .atomic)
                } else {
                    let damaged = directory.appendingPathComponent("configuration.invalid-\(Int(Date().timeIntervalSince1970)).json")
                    try prior.write(to: damaged, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: damaged.path)
                }
            }
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch { message = "配置未能保存：\(error.localizedDescription)" }
    }

    func rule(for id: String) -> ApplicationRule {
        configuration.rules[id] ?? ApplicationRule(name: catalog.first(where: { $0.id == id })?.name ?? id,
                                                   path: catalog.first(where: { $0.id == id })?.path)
    }

    func updateRule(_ id: String, _ mutation: (inout ApplicationRule) -> Void) {
        var value = rule(for: id)
        mutation(&value)
        if value.placement == .group && value.groupID == nil {
            value.groupID = configuration.groups.first?.id
        }
        if let app = catalog.first(where: { $0.id == id }) { value.name = app.name; value.path = app.path }
        change { $0.rules[id] = value }
    }

    func setHidden(_ hidden: Bool, for id: String) {
        let groups = Set(configuration.groups.map(\.id))
        updateRule(id) { $0.setHidden(hidden, validGroups: groups) }
    }

    func deleteGroup(_ id: String) {
        change { config in
            config.groups.removeAll { $0.id == id }
            for key in Array(config.rules.keys) where config.rules[key]?.groupID == id {
                config.rules[key]?.placement = .running; config.rules[key]?.groupID = nil
            }
        }
    }

    func setTopApplication(_ appID: String?, for groupID: String) {
        change { config in
            guard let index = config.groups.firstIndex(where: { $0.id == groupID }) else { return }
            config.groups[index].topApplicationID = appID
            if appID != nil { config.groups[index].symbol = "square.stack.3d.up" }
        }
    }

    func setGroupMembers(_ memberIDs: [String], for groupID: String) {
        guard configuration.groups.contains(where: { $0.id == groupID }) else { return }
        let records = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        change { config in
            config.replaceGroupMembers(memberIDs, in: groupID)
            for id in config.orderedMemberIDs(in: groupID) {
                if let app = records[id] {
                    config.rules[id]?.name = app.name
                    config.rules[id]?.path = app.path
                }
            }
        }
    }

    func removeApplication(_ appID: String, from groupID: String) {
        guard configuration.rules[appID]?.placement == .group,
              configuration.rules[appID]?.groupID == groupID else { return }
        change { config in
            config.rules[appID]?.placement = .running
            config.rules[appID]?.groupID = nil
        }
    }

    func moveGroup(_ id: String, by distance: Int) {
        change { c in
            guard let from = c.groups.firstIndex(where: { $0.id == id }) else { return }
            let to = max(0, min(c.groups.count - 1, from + distance))
            let group = c.groups.remove(at: from); c.groups.insert(group, at: to)
        }
    }

    func moveApplication(_ id: String, by distance: Int) {
        let all = orderedCatalog.map(\.id)
        change { c in
            var order = c.applicationOrder.filter { all.contains($0) }
            order += all.filter { !order.contains($0) }
            guard let from = order.firstIndex(of: id) else { return }
            let to = max(0, min(order.count - 1, from + distance))
            order.remove(at: from); order.insert(id, at: to); c.applicationOrder = order
        }
    }

    var orderedCatalog: [CatalogApplication] {
        let order = configuration.applicationOrder
        return catalog.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max, bi = order.firstIndex(of: b.id) ?? Int.max
            return ai == bi ? a.name.localizedStandardCompare(b.name) == .orderedAscending : ai < bi
        }
    }

    func updateRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let current = Set(apps.compactMap(\.bundleIdentifier))
        if current != runningIDs {
            runningIDs = current
            for app in apps {
                guard let id = app.bundleIdentifier, let url = app.bundleURL,
                      !catalog.contains(where: { $0.id == id }), !DockerConfiguration.protectedIDs.contains(id),
                      app.activationPolicy == .regular else { continue }
                catalog.append(CatalogApplication(id: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path))
            }
        }
    }

    func scanApplications() {
        guard !scanning else { return }
        scanning = true
        refreshTask?.cancel()
        refreshTask = Task {
            let records = await Task.detached(priority: .userInitiated) { Self.scanCatalogSynchronously() }.value
            guard !Task.isCancelled else { return }
            catalog = records.filter { !DockerConfiguration.protectedIDs.contains($0.id) }
            for (id, rule) in configuration.rules where !catalog.contains(where: { $0.id == id }) && !DockerConfiguration.protectedIDs.contains(id) {
                let candidate = rule.path.map { URL(fileURLWithPath: $0) } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                let validPath = candidate.flatMap { Bundle(url: $0.resolvingSymlinksInPath())?.bundleIdentifier == id ? $0.path : nil }
                catalog.append(CatalogApplication(id: id, name: rule.name.isEmpty ? id : rule.name, path: validPath ?? rule.path ?? "", installed: validPath != nil))
            }
            updateRunning(); scanning = false
            NotificationCenter.default.post(name: .dockerConfigurationChanged, object: self, userInfo: ["catalogChanged": true])
        }
    }

    private nonisolated static func scanCatalogSynchronously() -> [CatalogApplication] {
                var records: [String: CatalogApplication] = [:]
                let directories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Finder.app"]
                for path in directories {
                    let base = URL(fileURLWithPath: path)
                    if base.pathExtension == "app" { Self.collect(base, into: &records); continue }
                    guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    for case let url as URL in enumerator {
                        if url.pathExtension.lowercased() == "app" {
                            Self.collect(url, into: &records); enumerator.skipDescendants()
                        } else if enumerator.level > 4 { enumerator.skipDescendants() }
                    }
                }
                return Array(records.values)
    }

    private nonisolated static func collect(_ url: URL, into records: inout [String: CatalogApplication]) {
        let resolved = url.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: resolved), let id = bundle.bundleIdentifier, !id.isEmpty else { return }
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle.infoDictionary?["CFBundleDisplayName"]
                    ?? bundle.infoDictionary?["CFBundleName"]) as? String ?? url.deletingPathExtension().lastPathComponent
        if records[id] == nil { records[id] = .init(id: id, name: name, path: url.path) }
    }

    func icon(for app: CatalogApplication) -> NSImage {
        if let cached = iconCache[app.path] { return cached }
        let icon = app.installed ? NSWorkspace.shared.icon(forFile: app.path) : NSImage(systemSymbolName: "app.dashed", accessibilityDescription: app.name) ?? NSImage()
        iconCache[app.path] = icon
        return icon
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "导出 Docker 配置"; panel.nameFieldStringValue = "Docker-Forsyth.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(configuration).write(to: url, options: .atomic); message = "配置已导出。" }
        catch { message = "导出失败：\(error.localizedDescription)" }
    }

    func importConfiguration() {
        let panel = NSOpenPanel(); panel.title = "导入 Docker 配置"; panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try DockerConfiguration.decodeValidated(Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "导入这份 Docker 配置？"
            alert.informativeText = "将替换当前的应用规则、分组与外观设置。当前配置会自动备份。"
            alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            change { $0 = value }; message = "配置已导入。"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
}
