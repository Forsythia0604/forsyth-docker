import Foundation
import CoreGraphics

struct WindowRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

struct DockWindowGeometry: Codable, Hashable, Sendable {
    let screen: WindowRect
    let available: WindowRect
    let dock: WindowRect
}

struct DockWindowCommand: Codable, Sendable {
    enum Action: String, Codable, Sendable { case maximize, restore, authorize }
    let id: String
    let action: Action
    let timestamp: TimeInterval
    let processID: Int32?
}

struct DockWindowPacket: Codable, Sendable {
    let schemaVersion: Int
    let session: String
    let processID: Int32
    let timestamp: TimeInterval
    let enabled: Bool
    let geometry: DockWindowGeometry?
    let commands: [DockWindowCommand]
    var dockResizing: Bool? = nil
}

struct DockWindowStatus: Codable, Sendable {
    let schemaVersion: Int
    let session: String
    let timestamp: TimeInterval
    let trusted: Bool
    let code: String
    let suppressDock: Bool
    let adjustedWindows: Int
    let policyVersion: String
    var diagnostics: [WindowAdjustmentTrace]? = nil
    var manualWindows: Int? = nil
    var managedWindows: Int? = nil
    var nativeFullscreen: Bool? = nil
    var manualWindowDetails: [WindowManualPlacement]? = nil
    var monitoringMode: String? = nil
    var scanCount: Int? = nil
    var observedApplications: Int? = nil
    var observedWindows: Int? = nil
    var lastScanReason: String? = nil
    var shouldSuppressDock: Bool { nativeFullscreen ?? (code == "fullScreen") }
}

struct WindowManualPlacement: Codable, Sendable {
    let processID: Int32
    let frame: WindowRect
}

struct WindowAdjustmentTrace: Codable, Sendable {
    let processID: Int32
    let source: WindowRect
    let target: WindowRect
    let actual: WindowRect?
    let result: String
}

enum DockWindowPaths {
    static let heartbeatInterval: TimeInterval = 5
    static let freshnessInterval: TimeInterval = 15
    static let dockBundleID = "local.codex.native-dock-preview"
    static var testing: Bool { Bundle.main.object(forInfoDictionaryKey: "ForsythDevelopmentBuild") as? Bool == true }
    static var helperBundleID: String { testing ? "local.codex.dock-window-helper.testing" : "local.codex.dock-window-helper" }
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(testing ? "Library/Application Support/DockerForsyth/TestingWindows" : "Library/Application Support/DockStacks", isDirectory: true)
    }
    static var geometry: URL { directory.appendingPathComponent("geometry.json") }
    static var status: URL { directory.appendingPathComponent("status.json") }
    static var helper: URL {
        testing ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Dock 窗口助手.app")
            : directory.appendingPathComponent("Dock 窗口助手.app", isDirectory: true)
    }
    static var policy: URL { directory.appendingPathComponent("window-layout.js") }

    static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
