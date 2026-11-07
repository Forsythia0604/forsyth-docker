import AppKit

struct DockApplication: Identifiable {
    let name: String
    let bundleIdentifier: String
    let url: URL?
    let icon: NSImage
    var id: String { bundleIdentifier }
    var isInstalled: Bool { url != nil }
}

struct DockGroup: Identifiable {
    let id: String
    let name: String
    let applications: [DockApplication]
    let symbol: String
    let topApplicationID: String?
}

enum DockApplicationQuickAction: CaseIterable {
    case newWindow, incognitoWindow

    var title: String {
        switch self {
        case .newWindow: return "新建窗口"
        case .incognitoWindow: return "新建无痕窗口"
        }
    }

    var arguments: [String] {
        switch self {
        case .newWindow: return ["--new-window"]
        case .incognitoWindow: return ["--incognito", "--new-window"]
        }
    }
}

@MainActor
final class DockApplications: NSObject {
    static let finderID = "com.apple.finder"
    private(set) var groups: [DockGroup] = []
    private(set) var visibleApplications: [DockApplication] = []
    var onRunningApplicationsChange: (() -> Void)?
    var onRestoreMinimizedWindow: ((pid_t) -> Void)?
    private let workspace = NSWorkspace.shared
    private let store = DockerStore.shared
    private var runningObservation: NSKeyValueObservation?
    private var visibleFingerprint = ""

    override init() {
        super.init()
        runningObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.reload() }
        }
        reload(notify: false)
    }

    func reload(notify: Bool = true) {
        let config = store.configuration
        let regular = workspace.runningApplications.filter { !$0.isTerminated && $0.activationPolicy == .regular }
        let running = Set(regular.compactMap(\.bundleIdentifier))
        var available = Set(store.catalog.filter(\.installed).map(\.id))
        available.formUnion(regular.compactMap(\.bundleIdentifier))
        available.formUnion(config.rules.filter { $0.value.placement == .pinned }.keys)
        groups = config.groups.map { group in
            let ids = config.orderedMemberIDs(in: group.id)
            return DockGroup(id: group.id, name: group.name, applications: ids.map(makeApplication), symbol: group.symbol, topApplicationID: group.topApplicationID)
        }
        visibleApplications = PlacementResolver.standaloneIDs(configuration: config, running: running, available: available).map(makeApplication)
        let fingerprint = visibleApplications.map { $0.id + (running.contains($0.id) ? ":1" : ":0") }.joined(separator: "|")
            + groups.map { $0.id + ":" + $0.applications.filter { isRunning($0) }.map(\.id).joined(separator: ",") }.joined(separator: "|")
        let changed = fingerprint != visibleFingerprint
        visibleFingerprint = fingerprint
        if notify && changed { onRunningApplicationsChange?() }
    }

    func makeApplication(_ id: String) -> DockApplication {
        let entry = store.catalog.first { $0.id == id }
        let rule = store.rule(for: id)
        let candidate = (entry?.path ?? rule.path).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let url = resolveApplicationURL(for: id, candidate: candidate)
        let name = id == Self.finderID ? "访达" : entry?.name ?? (rule.name.isEmpty ? id : rule.name)
        return DockApplication(name: name, bundleIdentifier: id, url: url,
                               icon: url.map { workspace.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: name) ?? NSImage())
    }

    func isRunning(_ app: DockApplication) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.id).contains { !$0.isTerminated }
    }
    func isPinned(_ app: DockApplication) -> Bool {
        app.id == Self.finderID || store.rule(for: app.id).placement == .pinned
    }
    func setPinned(_ pinned: Bool, for app: DockApplication) {
        guard !DockerConfiguration.protectedIDs.contains(app.id) else { return }
        store.updateRule(app.id) { $0.placement = pinned ? .pinned : .running; $0.groupID = nil }
    }
    private func resolveApplicationURL(for id: String, candidate: URL?) -> URL? {
        if let candidate, candidate.isFileURL, candidate.pathExtension.lowercased() == "app", Bundle(url: candidate.resolvingSymlinksInPath())?.bundleIdentifier == id { return candidate }
        return workspace.urlForApplication(withBundleIdentifier: id)
    }

    func quickActions(for application: DockApplication) -> [DockApplicationQuickAction] {
        // AppKit does not expose another application's dynamic Dock menu.
        // Chrome forwards these explicit launch requests to its existing process.
        let chromeIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta",
                                     "com.google.Chrome.dev", "com.google.Chrome.canary"]
        return chromeIDs.contains(application.id) ? DockApplicationQuickAction.allCases : []
    }

    func perform(_ action: DockApplicationQuickAction, for application: DockApplication) throws {
        guard quickActions(for: application).contains(action) else { return }
        let runningURL = NSRunningApplication.runningApplications(withBundleIdentifier: application.id)
            .first(where: { !$0.isTerminated })?.bundleURL
        guard let url = resolveApplicationURL(for: application.id, candidate: runningURL ?? application.url),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == application.id,
              let executable = bundle.executableURL else {
            throw LaunchError.missingApplication(application.name)
        }
        let request = Process()
        request.executableURL = executable
        request.arguments = action.arguments
        request.standardInput = FileHandle.nullDevice
        request.standardOutput = FileHandle.nullDevice
        request.standardError = FileHandle.nullDevice
        // Do not wait: on a cold start this process is the browser itself.
        do { try request.run() }
        catch { throw LaunchError.openFailed(application.name, error) }
    }

    func open(
        _ application: DockApplication,
        files: [URL] = [],
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: application.id).first
        let savedURL = store.rule(for: application.id).path.map { URL(fileURLWithPath: $0) }
        let applicationURL = runningApp?.bundleURL
            ?? resolveApplicationURL(for: application.id, candidate: application.url ?? savedURL)
        guard let url = applicationURL else {
            completion(.failure(LaunchError.missingApplication(application.name)))
            return
        }

        Task {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.promptsUserIfNeeded = false

            do {
                if !files.isEmpty {
                    _ = try await workspace.open(files, withApplicationAt: url, configuration: configuration)
                } else if application.id == "com.deepseek.dsh",
                          runningApp?.isFinishedLaunching == true,
                          let reopen = URL(string: "dsh://open"),
                          (try? await workspace.open([reopen], withApplicationAt: url, configuration: configuration)) != nil {
                    // DSH's reopen URL restores or recreates its existing primary window.
                } else {
                    let app = try await workspace.openApplication(at: url, configuration: configuration)
                    if runningApp?.processIdentifier == app.processIdentifier {
                        onRestoreMinimizedWindow?(app.processIdentifier)
                    }
                }
                completion(.success(()))
            } catch {
                completion(.failure(LaunchError.openFailed(application.name, error)))
            }
        }
    }


    private enum LaunchError: LocalizedError {
        case missingApplication(String)
        case openFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .missingApplication(let name):
                return "找不到「\(name)」的应用程序。"
            case .openFailed(let name, let underlying):
                return "无法打开「\(name)」。\(underlying.localizedDescription)"
            }
        }
    }
}
