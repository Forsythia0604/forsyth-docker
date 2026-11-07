import AppKit
import CoreFoundation

@MainActor
final class TrashService {
    private(set) var state: TrashState = .unknown
    private(set) var isEmptying = false
    private(set) var lastAction = "none"

    static var homeURL: URL {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    func refresh() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let native = CFPreferencesCopyAppValue("trash-full" as CFString, "com.apple.dock" as CFString) as? Bool
        var directories = [Self.homeURL]
        if native == nil {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            directories += volumes.map { $0.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true) }
        }
        state = TrashStateDetector.detect(systemFull: native, directories: directories)
    }

    func confirmAndEmpty() {
        guard !DockerStore.isPreview, !isEmptying else { return }
        refresh()
        guard state != .empty else { DockerStore.shared.message = "废纸篓已经是空的。"; return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(named: NSImage.trashFullName)
        alert.messageText = "要永久清倒废纸篓吗？"
        alert.informativeText = "废纸篓中的所有项目将永久删除，无法撤销。"
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let destructive = alert.addButton(withTitle: "清倒废纸篓")
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        alert.window.initialFirstResponder = cancel
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window === alert.window && event.keyCode == 53 {
                NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
                return nil
            }
            return event
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        NSApplication.shared.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { lastAction = "cancelled"; return }
        isEmptying = true; lastAction = "requested"
        Task {
            let failure = await Task.detached(priority: .userInitiated) { FinderTrashCommand.empty() }.value
            isEmptying = false
            refresh()
            if let failure {
                lastAction = failure.cancelled ? "cancelled" : "failed"
                guard !failure.cancelled else { return }
                let message = failure.code == -1743
                    ? "请在“系统设置 → 隐私与安全 → 自动化”中允许 Docker 控制访达，然后重试。"
                    : failure.message
                DockerStore.shared.message = "未能清倒废纸篓：\(message)"
                let errorAlert = NSAlert()
                errorAlert.messageText = "未能清倒废纸篓"
                errorAlert.informativeText = message
                errorAlert.addButton(withTitle: "好")
                errorAlert.addButton(withTitle: "打开废纸篓")
                NSApplication.shared.activate()
                if errorAlert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Self.homeURL) }
            } else {
                lastAction = "completed"
                DockerStore.shared.message = "已将清倒操作交给访达。"
            }
        }
    }
}

private enum FinderTrashCommand {
    struct Failure: Sendable {
        let code: Int
        let message: String
        var cancelled: Bool { code == -128 }
    }

    static func empty() -> Failure? {
        // Finder.sdef defines the native Empty Trash command as 'fndr' / 'empt'.
        // Only send it after the explicit destructive confirmation above.
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let event = NSAppleEventDescriptor(eventClass: 0x666E6472, eventID: 0x656D7074,
                                           targetDescriptor: target, returnID: -1, transactionID: 0)
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract, .canSwitchLayer], timeout: 120)
            let code = Int(reply.paramDescriptor(forKeyword: 0x6572726E)?.int32Value ?? 0)
            if code != 0 {
                return Failure(code: code, message: reply.paramDescriptor(forKeyword: 0x65727273)?.stringValue ?? "访达返回错误 \(code)。")
            }
            return nil
        } catch let error as NSError { return Failure(code: error.code, message: error.localizedDescription) }
    }
}
