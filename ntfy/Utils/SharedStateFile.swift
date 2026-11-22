import Foundation

/// Mutual exclusion across the app and its extension for a small read-modify-write of shared
/// defaults. Reentrant within a process; process death releases it.
final class SharedFileLock {
    private static var registry: [String: SharedFileLock] = [:]
    private static let registryLock = NSLock()

    /// The lock for `name` in the app group container (temporary directory without one).
    static func named(_ name: String) -> SharedFileLock {
        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let path = directory.appendingPathComponent(name).path
        registryLock.lock(); defer { registryLock.unlock() }
        if let lock = registry[path] { return lock }
        let lock = SharedFileLock(path: path)
        registry[path] = lock
        return lock
    }

    private let path: String
    private let local = NSRecursiveLock()
    private var depth = 0
    private var descriptor: Int32 = -1

    /// A separate lock object on `path` contends like another process would (its own descriptor).
    init(path: String) { self.path = path }

    /// How long a caller waits for the lock before skipping its operation.
    static let defaultTimeout: TimeInterval = 2

    /// Runs `body` holding the lock. Acquisition is bounded: when another process holds the lock
    /// past `timeout` (a suspended extension, say) or the lock file can't be opened, `body` doesn't
    /// run and the result is nil. Nothing ever runs unlocked (review-130b #1).
    @discardableResult
    func withLock<T>(timeout: TimeInterval = SharedFileLock.defaultTimeout, _ body: () throws -> T) rethrows -> T? {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        guard local.lock(before: Date().addingTimeInterval(timeout)) else {
            Log.w("SharedFileLock", "Lock busy in this process; skipping")
            return nil
        }
        defer { local.unlock() }
        if depth == 0 {
            let fd = Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o600))
            guard fd >= 0 else {
                Log.w("SharedFileLock", "Cannot open lock file; skipping")
                return nil
            }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < end else {
                    Darwin.close(fd)
                    Log.w("SharedFileLock", "Lock held elsewhere past \(timeout)s; skipping")
                    return nil
                }
                usleep(5_000)
            }
            descriptor = fd
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0, descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
        }
        return try body()
    }
}

/// One JSON value in its own app-group file, shared by the app and the extension. Every read goes
/// to disk (no per-process cache such as UserDefaults keeps), every write replaces the file
/// atomically, and every change is a read-modify-write under `lock` (review-130b #1, D).
final class SharedStateFile<Value: Codable> {
    let url: URL
    let lock: SharedFileLock

    static var sharedDirectory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    init(name: String, directory: URL = SharedStateFile.sharedDirectory, lock: SharedFileLock? = nil) {
        url = directory.appendingPathComponent(name)
        self.lock = lock ?? SharedFileLock(path: directory.appendingPathComponent(name + ".lock").path)
    }

    /// The value on disk now, nil if there is none (or it can't be decoded).
    func read() -> Value? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    /// Read-modify-write under the lock. `change` gets the value on disk (nil if none) and returns
    /// whether to write. Returns `change`'s value, or nil when the lock wasn't had in time or the
    /// write failed (then nothing changed on disk).
    func update<R>(timeout: TimeInterval = SharedFileLock.defaultTimeout, _ change: (inout Value?) -> (write: Bool, result: R)) -> R? {
        lock.withLock(timeout: timeout) { () -> R? in
            var value = read()
            let outcome = change(&value)
            guard outcome.write else { return outcome.result }
            do {
                if let value {
                    try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return outcome.result
            } catch {
                Log.w("SharedStateFile", "Cannot write \(url.lastPathComponent)", error)
                return nil
            }
        } ?? nil
    }
}
