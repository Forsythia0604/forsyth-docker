import AppKit
import Darwin

@main
@MainActor
struct DockerWatchdog {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let token = CommandLine.arguments[2]
        while true {
            guard let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(NativeDockSession.self, from: data),
                  session.token == token else { return }
            if !session.ownerIsAlive() {
                _ = session.restore(at: url)
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
