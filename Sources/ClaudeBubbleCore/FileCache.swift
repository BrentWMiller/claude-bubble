import Darwin
import Foundation

/// Decoded files, kept until the file changes (by inode, size and modification time): the hook replaces a session's
/// file on every event, so a reload only decodes the files that actually changed. Not thread-safe: one queue's.
public final class FileCache<Value> {
    private struct Stamp: Equatable {
        let inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    }

    private var entries: [String: (stamp: Stamp, value: Value?)] = [:]

    public init() {}

    /// The file's decoded value: cached while the file is unchanged, else read and decoded again. Nil when the file
    /// is gone or doesn't decode (and that's cached too).
    public func value(at url: URL, decode: (Data) -> Value?) -> Value? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            entries[url.path] = nil
            return nil
        }
        let stamp = Stamp(inode: info.st_ino, size: info.st_size,
                          seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        if let entry = entries[url.path], entry.stamp == stamp { return entry.value }
        let value = (try? Data(contentsOf: url)).flatMap(decode)
        entries[url.path] = (stamp, value)
        return value
    }

    /// Forgets files not in `paths` (deleted sessions).
    public func prune(keeping paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}
