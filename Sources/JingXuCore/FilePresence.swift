import Darwin
import Foundation

public enum FilePresence: Sendable { case present, missing }
public typealias FilePresenceProbe = @Sendable (URL) throws -> FilePresence

public enum FilePresenceReader {
    /// Only ENOENT is absence. lstat deliberately treats dangling symlinks as occupied.
    public static func read(_ url: URL) throws -> FilePresence {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present }
        let code = errno
        guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        // Confirm the nearest existing parent is readable; an unavailable directory is
        // not evidence that its children are gone. Planned archive parents may not exist yet.
        var parent = url.deletingLastPathComponent()
        while true {
            if let directory = opendir(parent.path) { closedir(directory); return .missing }
            let error = errno
            guard error == ENOENT, parent.path != "/" else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            parent.deleteLastPathComponent()
        }
    }
}
