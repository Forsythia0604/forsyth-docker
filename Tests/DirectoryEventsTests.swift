import Foundation

@main @MainActor
struct DirectoryEventsTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("docker-directory-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = DirectoryEvents()
        var changes = 0
        watcher.start(at: directory) { changes += 1 }
        let file = directory.appendingPathComponent("geometry.json")
        try await Task.sleep(for: .milliseconds(50))
        precondition(changes == 0, "An idle directory does not invoke the observer")
        try Data("first".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        precondition(changes > 0, "The initial atomic publication is delivered")
        let first = changes
        try Data("second".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        precondition(changes > first, "Replacing the inode continues to deliver changes")
        watcher.stop()
        try await Task.sleep(for: .milliseconds(50))
        let stopped = changes
        try Data("after stop".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(200))
        precondition(changes == stopped, "Stopping removes the event source")
        watcher.stop()
        print("PASS: 4 idle, atomic replacement and observer shutdown assertions")
    }
}
