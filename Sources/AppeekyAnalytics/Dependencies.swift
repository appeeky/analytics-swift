import Foundation
import os

/// Small key-value files: the persisted state and the event queue.
protocol KeyValueStorage: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ data: Data)
}

/// Sends one HTTP request and returns its status code and body.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

enum CoarseValue: String, Sendable {
    case low, medium, high
}

/// Apple-only capabilities; every one is optional so the client logic runs anywhere.
protocol NativeBridge: Sendable {
    /// `AAAttribution.attributionToken()`.
    func adServicesToken() async -> String?
    /// SKAdNetwork / AdAttributionKit conversion value update.
    func updateConversionValue(fine: Int, coarse: CoarseValue, lockWindow: Bool) async
}

typealias CancelHandle = @Sendable () -> Void

struct CoreDependencies: Sendable {
    var storage: KeyValueStorage
    var transport: HTTPTransport
    var native: NativeBridge?
    /// Milliseconds since 1970, like `Date.now()`.
    var now: @Sendable () -> Int64
    var randomId: @Sendable () -> String
    var deviceContext: @Sendable () -> DeviceContext
    /// URL the app was opened with, for campaign links.
    var launchURL: (@Sendable () async -> String?)?
    var sleep: @Sendable (_ ms: Int64) async -> Void
    /// Runs `action` every `ms` until the returned handle is called.
    var startInterval: @Sendable (_ ms: Int64, _ action: @escaping @Sendable () async -> Void) -> CancelHandle
    var log: @Sendable (_ message: String) -> Void
    /// The process was launched in the background (background fetch, a silent
    /// push…); the first session then starts when the app comes to the foreground.
    var launchedInBackground: Bool = false
}

// MARK: - Defaults

/// Stores each key as a JSON file in Application Support/AppeekyAnalytics.
final class FileStorage: KeyValueStorage, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    static func applicationSupport() -> FileStorage {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return FileStorage(directory: base.appendingPathComponent("AppeekyAnalytics", isDirectory: true))
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    func read(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: fileURL(key))
    }

    func write(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            // Readable after the first unlock, so background flushes still work.
            try data.write(to: fileURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL(key), options: [.atomic])
            #endif
        } catch {
            // Losing one write is better than crashing the app; the next write retries.
        }
    }
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    static func make() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

let sdkLogger = Logger(subsystem: "com.appeeky.analytics", category: "AppeekyAnalytics")

@Sendable func defaultStartInterval(_ ms: Int64, _ action: @escaping @Sendable () async -> Void) -> CancelHandle {
    let task = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(max(ms, 1)) * 1_000_000)
            if Task.isCancelled { break }
            await action()
        }
    }
    return { task.cancel() }
}

@Sendable func defaultSleep(_ ms: Int64) async {
    try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
}

@Sendable func currentTimeMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

/// Resolves once with the first value; later calls are ignored.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// The provider's answer, or nil when it takes longer than `ms` (the provider
/// keeps running, but nobody waits for it).
func withTimeout<T: Sendable>(_ ms: Int64, _ provider: (@Sendable () async -> T?)?) async -> T? {
    guard let provider else { return nil }
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce(continuation)
        Task { once.resume(await provider()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            once.resume(nil)
        }
    }
}
