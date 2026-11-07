import Foundation

enum TrashState: String, Sendable {
    case empty, full, unknown
}

enum TrashStateDetector {
    static func detect(systemFull: Bool?, directories: [URL], fileManager: FileManager = .default) -> TrashState {
        // The Dock tracks the combined trash across mounted disks, and can read
        // it even when this application cannot enumerate a protected folder.
        if let systemFull { return systemFull ? .full : .empty }
        var unreadable = false
        for directory in directories {
            do {
                let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                if entries.contains(where: { ![".DS_Store", ".localized"].contains($0.lastPathComponent) }) { return .full }
            } catch let error as NSError {
                if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError { unreadable = true }
            }
        }
        return unreadable ? .unknown : .empty
    }
}
