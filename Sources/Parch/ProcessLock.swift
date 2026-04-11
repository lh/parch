import Foundation

/// File-based exclusive lock using POSIX flock(). Prevents overlapping parch runs.
final class ProcessLock {
    private let fd: Int32
    let path: String

    /// Attempts to acquire an exclusive lock. Returns nil if another process holds it.
    static func acquire() -> ProcessLock? {
        let lockPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parch/parch.lock").path

        let fd = open(lockPath, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return nil }

        // Non-blocking exclusive lock
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }

        return ProcessLock(fd: fd, path: lockPath)
    }

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
