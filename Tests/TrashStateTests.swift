import Foundation

@main
struct TrashStateTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DockerTrashTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        var checks = 0
        func check(_ actual: TrashState, _ expected: TrashState) {
            checks += 1; precondition(actual == expected, "Unexpected trash state: \(actual), expected \(expected)")
        }
        check(TrashStateDetector.detect(systemFull: true, directories: [first]), .full)
        check(TrashStateDetector.detect(systemFull: nil, directories: [first]), .empty)
        try Data().write(to: first.appendingPathComponent(".DS_Store"))
        try Data().write(to: first.appendingPathComponent(".localized"))
        check(TrashStateDetector.detect(systemFull: nil, directories: [first]), .empty)
        try Data().write(to: second.appendingPathComponent(".hidden-user-document"))
        check(TrashStateDetector.detect(systemFull: nil, directories: [first, second]), .full)
        check(TrashStateDetector.detect(systemFull: false, directories: [second]), .empty)
        let unreadable = root.appendingPathComponent("not-a-directory")
        try Data().write(to: unreadable)
        check(TrashStateDetector.detect(systemFull: nil, directories: [unreadable]), .unknown)
        check(TrashStateDetector.detect(systemFull: true, directories: [unreadable]), .full)
        check(TrashStateDetector.detect(systemFull: nil, directories: [unreadable, second]), .full)
        check(TrashStateDetector.detect(systemFull: nil, directories: [root.appendingPathComponent("absent")]), .empty)
        print("PASS: \(checks) system-trash, hidden-file and unreadable-folder assertions")
    }
}
