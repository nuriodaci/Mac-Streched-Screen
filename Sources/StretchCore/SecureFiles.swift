import Foundation
import Darwin

/// All persisted state is private to the current user. Never follow a final-component symlink,
/// truncate an existing backup, or use predictable temporary names.
enum SecureFiles {
    static func directory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw posixError() }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw posixError() }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw StretchError.backupWriteFailed("State directory must be owned by you and not be a symbolic link.")
        }
        guard chmod(url.path, 0o700) == 0 else { throw posixError() }
    }

    static func read(_ url: URL, maximum: Int = 32_768) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= maximum else {
            throw StretchError.backupCorrupted("Invalid state file type, owner, or size.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        // Bound the read itself too: a file may grow after fstat. Nonblocking open lets
        // us reject a FIFO without waiting indefinitely for another process to open it.
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else {
            throw StretchError.backupCorrupted("State file grew beyond the size limit.")
        }
        return data
    }

    static func create(_ url: URL, data: Data) throws {
        try directory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw posixError() }
        // link() is create-only; unlike rename(), it cannot replace a different backup.
        guard link(temporary.path, url.path) == 0 else { throw posixError() }
        unlink(temporary.path)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw posixError() }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Cross-process transaction lock. Lock files are never unlinked while a process might hold them.
final class FileLock {
    private let fd: Int32

    init(_ url: URL, nonblocking: Bool = false) throws {
        try SecureFiles.directory(url.deletingLastPathComponent())
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecureFiles.posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            close(fd)
            throw StretchError.backupWriteFailed("Invalid lock file.")
        }
        if flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
            close(fd)
            throw StretchError.invalidInput("Another operation is in progress. Please try again.")
        }
    }

    deinit { flock(fd, LOCK_UN); close(fd) }
}
