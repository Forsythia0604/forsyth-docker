import AppKit
import CoreServices
import Security

@MainActor
enum NativeQuitControl {
    private static var registrationError: String?
    private static var retry: Timer?
    private static var embeddedHostURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DockerControlHost.app")
    }
    static var hostURL: URL {
        let testing = Bundle.main.object(forInfoDictionaryKey: "ForsythDevelopmentBuild") as? Bool == true
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockerForsyth/ControlCenter")
            .appendingPathComponent(testing ? "Testing" : "Release")
            .appendingPathComponent("Docker.app")
    }
    static var executableURL: URL { hostURL.appendingPathComponent("Contents/MacOS/DockerControlHost") }

    static func register() {
        do {
            guard try installProvider() else {
                // Never replace a provider while it is handling a quit request.
                retry?.invalidate()
                retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { register() }
                }
                return
            }
            retry?.invalidate(); retry = nil
            let status = LSRegisterURL(hostURL as CFURL, true)
            guard status == noErr else { throw failure("系统暂时无法登记一键退出控件。", code: Int(status)) }
            registrationError = nil
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = ["--register-controls"]
            NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration) { _, error in
                if let error { Task { @MainActor in registrationError = error.localizedDescription } }
            }
        } catch { registrationError = error.localizedDescription }
    }

    private static func failure(_ description: String, code: Int = 1) -> NSError {
        NSError(domain: "ForsythDockerControl", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private static func signature(of url: URL, validate: Bool) throws -> [String: Any] {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw failure("无法读取控件签名。", code: Int(status)) }
        if validate {
            status = SecStaticCodeCheckValidity(code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil)
            guard status == errSecSuccess else { throw failure("一键退出控件签名验证失败。", code: Int(status)) }
        }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let result = information as? [String: Any] else {
            throw failure("无法读取控件签名信息。", code: Int(status))
        }
        return result
    }

    private static func installProvider() throws -> Bool {
        let manager = FileManager.default
        let source = try signature(of: embeddedHostURL, validate: true)
        let main = try signature(of: Bundle.main.bundleURL, validate: false)
        guard let team = source[kSecCodeInfoTeamIdentifier as String] as? String,
              team == main[kSecCodeInfoTeamIdentifier as String] as? String,
              let hash = source[kSecCodeInfoUnique as String] as? Data,
              let identifier = source[kSecCodeInfoIdentifier as String] as? String else {
            throw failure("一键退出控件与 Docker 的签名不一致。")
        }
        if let installed = try? signature(of: hostURL, validate: true),
           installed[kSecCodeInfoUnique as String] as? Data == hash,
           installed[kSecCodeInfoTeamIdentifier as String] as? String == team { return true }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else { return false }

        // WidgetKit excludes providers nested inside another application bundle.
        // Keep the signed source embedded and install its single active copy here.
        let directory = hostURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let stage = directory.appendingPathComponent(".install-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        let staged = stage.appendingPathComponent("Docker.app")
        try manager.copyItem(at: embeddedHostURL, to: staged)
        let copied = try signature(of: staged, validate: true)
        guard copied[kSecCodeInfoUnique as String] as? Data == hash else {
            throw failure("一键退出控件复制验证失败。")
        }
        var previous: NSURL?
        if manager.fileExists(atPath: hostURL.path) {
            try manager.trashItem(at: hostURL, resultingItemURL: &previous)
        }
        do { try manager.moveItem(at: staged, to: hostURL) }
        catch {
            if let previous { try? manager.moveItem(at: previous as URL, to: hostURL) }
            throw error
        }
        return true
    }

    static func snapshot(in directory: URL) -> [String: Any] {
        var result: [String: Any] = ["provider": "native-control", "kind": "local.forsyth.docker.quit",
                                     "invocations": 0, "processing": false]
        if let registrationError { result["registrationError"] = registrationError }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("quit-control-last.json")),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           report["provider"] as? String == "native-control" {
            result["lastInvocation"] = report
            result["invocations"] = report["sequence"] ?? 1
            result["processing"] = report["processing"] ?? false
            result["summary"] = report["summary"] ?? ""
        }
        return result
    }

    static func printStatusAndExit() -> Never {
        let task = Process(); task.executableURL = executableURL
        task.arguments = ["--control-center-status"]
        task.standardOutput = FileHandle.standardOutput; task.standardError = FileHandle.standardError
        do { try task.run(); task.waitUntilExit(); exit(task.terminationStatus) }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
