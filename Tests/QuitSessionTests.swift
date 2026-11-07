import Foundation

@main
struct QuitSessionTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("docker-quit-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = QuitSessionLease.acquire(in: directory)
        precondition(first != nil, "First quit operation acquires the session")
        precondition(QuitSessionLease.acquire(in: directory) == nil, "Concurrent quit operation is refused")
        first?.release()
        let next = QuitSessionLease.acquire(in: directory)
        precondition(next != nil, "A completed operation releases the next request")
        next?.release(); next?.release()
        precondition(QuitSessionLease.acquire(in: directory) != nil, "Repeated release is safe")
        print("PASS: 4 quit-session concurrency assertions")
    }
}
