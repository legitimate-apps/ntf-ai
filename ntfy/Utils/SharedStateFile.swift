// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
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
        return at(directory, name)
    }

    /// The one lock object in this process for `name` in `directory` (the app group in the app,
    /// a scratch directory in tests), so everything keyed on a directory shares its lock.
    static func at(_ directory: URL, _ name: String) -> SharedFileLock {
        let path = directory.appendingPathComponent(name).path
        registryLock.lock(); defer { registryLock.unlock() }
        if let lock = registry[path] { return lock }
        let lock = SharedFileLock(path: path)
        registry[path] = lock
        return lock
    }

    let path: String
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

    /// What the file holds: nothing yet (eligible for migration from older storage), a value, or
    /// something that can't be read now (protected before first unlock, corrupt). Unreadable is
    /// never treated as empty (review-130c C3).
    enum Load {
        case missing
        case value(Value)
        case unreadable

        var value: Value? { if case .value(let value) = self { return value }; return nil }
    }

    init(url: URL, lock: SharedFileLock) {
        self.url = url
        self.lock = lock
    }

    func load() -> Load {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .missing
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { return .unreadable }
        return .value(value)
    }

    /// The value on disk now, nil if there is none or it can't be read.
    func read() -> Value? { load().value }

    /// Read-modify-write under the lock. `change` gets the value on disk (nil if none) and returns
    /// whether to write. Returns `change`'s value only once it is committed: nil when the lock
    /// wasn't had in time, the file can't be read (an unreadable file is never overwritten as if
    /// empty), or the write failed. Then nothing changed on disk.
    func update<R>(timeout: TimeInterval = SharedFileLock.defaultTimeout, _ change: (inout Value?) -> (write: Bool, result: R)) -> R? {
        lock.withLock(timeout: timeout) { () -> R? in
            var value: Value?
            switch load() {
            case .missing: value = nil
            case .value(let stored): value = stored
            case .unreadable:
                Log.w("SharedStateFile", "\(url.lastPathComponent) can't be read; not changing it")
                return nil
            }
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
