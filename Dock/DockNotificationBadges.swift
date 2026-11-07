import AppKit

@MainActor
final class DockNotificationBadges {
    var onChange: (([String: String]) -> Void)?

    private var badges: [String: String] = [:]
    private var timer: Timer?
    private var refreshing = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    private func refresh() {
        guard !refreshing else { return }
        let applications: [(id: String, pid: pid_t)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return (id, app.processIdentifier)
        }
        refreshing = true
        Task { [weak self] in
            let updated = await Task.detached(priority: .utility) {
                DockStatusLabelReader.read(applications)
            }.value
            guard let self else { return }
            self.refreshing = false
            guard self.badges != updated else { return }
            self.badges = updated
            self.onChange?(updated)
        }
    }
}

private enum DockStatusLabelReader {
    private typealias CreateASN = @convention(c) @Sendable (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyInformation = @convention(c) @Sendable (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    // LaunchServices stores the label independently of the system Dock's
    // visibility. Resolve its private entry points at runtime so an OS that
    // lacks them can still run the Dock without badge data.
    private static let functions: (create: CreateASN, copy: CopyInformation)? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/CoreServices"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else {
            dlclose(handle)
            return nil
        }
        return (unsafeBitCast(create, to: CreateASN.self), unsafeBitCast(copy, to: CopyInformation.self))
    }()

    private static let defaultSessionID: Int32 = -2

    static func read(_ applications: [(id: String, pid: pid_t)]) -> [String: String] {
        guard let functions else { return [:] }
        var badges: [String: String] = [:]
        for (id, pid) in applications where badges[id] == nil {
            guard let asn = functions.create(nil, pid)?.takeRetainedValue(),
                  let info = functions.copy(defaultSessionID, asn, "StatusLabel" as CFString)?
                    .takeRetainedValue() as? [String: Any],
                  let label = info["label"] as? String else { continue }
            let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { badges[id] = text }
        }
        return badges
    }
}
