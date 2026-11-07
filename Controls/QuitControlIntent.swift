import AppIntents
import Foundation
import OSLog

@MainActor
enum DockerQuitControlDispatch {
    private static var handler: (() async -> Void)?
    private static var pending: [CheckedContinuation<Void, Never>] = []
    static func install(_ action: @escaping () async -> Void) {
        handler = action
        let waiting = pending; pending.removeAll()
        waiting.forEach { $0.resume() }
    }
    static func request() async {
        if handler == nil {
            await withCheckedContinuation { pending.append($0) }
        }
        await handler?()
    }
}

struct DockerQuitControlIntent: AppIntent {
    static let title: LocalizedStringResource = "一键退出"
    static let description = IntentDescription("正常退出其他应用，保留 Docker 中设置的保留名单。")
    // The same intent belongs to the app and extension. Run in the app so the
    // existing quit service, saved rules and save-prompt handling are shared.
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "local.forsyth.docker", category: "QuitControl").info(
            "Perform quit intent in \(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public), pid \(ProcessInfo.processInfo.processIdentifier)"
        )
        await DockerQuitControlDispatch.request()
        return .result()
    }
}
