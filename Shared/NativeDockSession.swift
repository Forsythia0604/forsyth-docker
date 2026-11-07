import AppKit
import CoreFoundation
import Darwin

enum DockEngineClient {
    static func send(_ command: DockCommand, timeout: TimeInterval = 1.5) -> ControlResponse? {
        guard let port = CFMessagePortCreateRemote(nil, DockLockInfo.controlPortName as CFString) else { return nil }
        var reply: Unmanaged<CFData>?
        let data = ControlCodec.encode(ControlRequest.command(command, wait: false))
        let code = CFMessagePortSendRequest(port, 0, data as CFData, timeout, timeout,
                                            CFRunLoopMode.defaultMode.rawValue, &reply)
        guard code == Int32(kCFMessagePortSuccess), let reply else { return nil }
        return ControlCodec.decode(ControlResponse.self, from: reply.takeRetainedValue() as Data)
    }
    static func report() -> StatusReport? {
        guard let json = send(.status)?.json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StatusReport.self, from: data)
    }
}

@MainActor
enum NativeSystemDock {
    private typealias GetAutoHide = @convention(c) () -> Bool
    private typealias SetAutoHide = @convention(c) (Bool) -> Void
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static var get: GetAutoHide? {
        _ = handle
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: GetAutoHide.self) }
    }
    private static var set: SetAutoHide? {
        _ = handle
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: SetAutoHide.self) }
    }
    static var autoHide: Bool {
        if let get { return get() }
        return CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }
    static func setAutoHide(_ value: Bool) {
        if let set { set(value); return }
        CFPreferencesSetAppValue("autohide" as CFString, value as CFBoolean, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); task.arguments = ["Dock"]
        try? task.run()
    }
}

struct NativeDockSession: Codable, Sendable {
    let token: String
    let ownerPID: Int32
    let ownerLaunchDate: Date?
    let settings: Data?
    let autoHide: Bool
    let date: Date

    @MainActor static func capture() -> Self {
        Self(token: UUID().uuidString, ownerPID: getpid(),
             ownerLaunchDate: NSRunningApplication.current.launchDate,
             settings: CFPreferencesCopyAppValue("settings.v1" as CFString, "dev.yihui.docklock" as CFString) as? Data,
             autoHide: NativeSystemDock.autoHide, date: Date())
    }

    @MainActor func ownerIsAlive() -> Bool {
        guard let owner = NSRunningApplication(processIdentifier: ownerPID), !owner.isTerminated,
              owner.bundleIdentifier == "local.codex.native-dock-preview" else { return false }
        if let ownerLaunchDate, let date = owner.launchDate { return abs(date.timeIntervalSince(ownerLaunchDate)) < 1 }
        return kill(ownerPID, 0) == 0
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @MainActor @discardableResult
    func restore(at url: URL) -> Bool {
        guard let current = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
              current.token == token else { return false }
        _ = DockEngineClient.send(.setEnabled(false))
        _ = DockEngineClient.send(.setHideDock(false))
        _ = DockEngineClient.send(.quit)
        for _ in 0..<30 {
            if CFMessagePortCreateRemote(nil, DockLockInfo.controlPortName as CFString) == nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // The original settings document is retained for using standalone DockLock later.
        CFPreferencesSetAppValue("settings.v1" as CFString, settings as CFData?, "dev.yihui.docklock" as CFString)
        CFPreferencesSetAppValue("autoHideEnabledByDockLock" as CFString, false as CFBoolean, "dev.yihui.docklock" as CFString)
        CFPreferencesAppSynchronize("dev.yihui.docklock" as CFString)
        NativeSystemDock.setAutoHide(autoHide)
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
