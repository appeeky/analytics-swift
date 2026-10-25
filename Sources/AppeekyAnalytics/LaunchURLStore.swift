import Foundation

/// The URL that opened the app. A native app hands it over through
/// ``Appeeky/handleOpenURL(_:)`` and friends, which usually run after
/// `configure`, so first-launch attribution waits a moment for it.
final class LaunchURLStore: @unchecked Sendable {
    static let shared = LaunchURLStore()

    private let lock = NSLock()
    private var url: URL?
    private var waiters: [CheckedContinuation<URL?, Never>] = []

    var current: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    /// Keeps the first URL: it is the one that launched the app.
    func record(_ newURL: URL) {
        lock.lock()
        guard url == nil else {
            lock.unlock()
            return
        }
        url = newURL
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: newURL) }
    }

    /// The launch URL, waiting up to `ms` for one to arrive.
    func wait(ms: Int64) async -> URL? {
        if let current { return current }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            lock.lock()
            if let url {
                lock.unlock()
                continuation.resume(returning: url)
                return
            }
            waiters.append(continuation)
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                self.timeOut()
            }
        }
    }

    private func timeOut() {
        lock.lock()
        let pending = waiters
        waiters = []
        let value = url
        lock.unlock()
        pending.forEach { $0.resume(returning: value) }
    }

    /// Tests only.
    func reset() {
        lock.lock()
        url = nil
        lock.unlock()
    }
}
