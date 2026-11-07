import Foundation
import Darwin

/// Watch the directory because an atomic JSON write replaces its inode.
@MainActor
final class DirectoryEvents {
    private var source: DispatchSourceFileSystemObject?

    func start(at directory: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
