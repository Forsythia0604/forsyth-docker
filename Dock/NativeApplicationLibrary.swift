import AppKit

@MainActor
enum NativeApplicationLibrary {
    static var launcherURL: URL? {
        for (path, identifier) in [
            ("/System/Applications/Apps.app", "com.apple.apps.launcher"),
            ("/System/Applications/Launchpad.app", "com.apple.launchpad.launcher")
        ] {
            let url = URL(fileURLWithPath: path)
            if Bundle(url: url)?.bundleIdentifier == identifier { return url }
        }
        return nil
    }

    static var icon: NSImage {
        launcherURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "系统应用列表") ?? NSImage()
    }

    static func open() {
        guard let launcherURL else {
            DockerStore.shared.message = "未找到系统 App 入口，请检查系统“应用程序”中的 App 应用。"
            return
        }
        Task {
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true; options.createsNewApplicationInstance = false
            do { _ = try await NSWorkspace.shared.openApplication(at: launcherURL, configuration: options) }
            catch { DockerStore.shared.message = "系统应用列表未能打开：\(error.localizedDescription)" }
        }
    }
}
