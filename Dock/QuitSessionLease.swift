import Foundation
import Darwin

final class QuitSessionLease {
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(in directory: URL) -> QuitSessionLease? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("quit-session.lock")
        let descriptor = file.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); return nil }
        return QuitSessionLease(descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1
    }
    deinit { release() }
}
