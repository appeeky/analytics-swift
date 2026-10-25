import Foundation
@testable import AppeekyAnalytics

final class MemoryStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func write(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }

    func json(_ key: String) -> Any? {
        read(key).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}

struct SentBatch {
    let url: URL
    let headers: [String: String]
    let raw: Data
    let body: [String: Any]

    var events: [[String: Any]] { body["events"] as? [[String: Any]] ?? [] }
    var eventNames: [String] { events.compactMap { $0["name"] as? String } }
    var context: [String: Any] { body["context"] as? [String: Any] ?? [:] }
    var attribution: [String: Any]? { body["attribution"] as? [String: Any] }
}

struct OfflineError: Error {}

/// Answers ingest requests with the queued statuses (202 when empty, -1 = offline)
/// and AdServices requests with `adServices` (404 by default).
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private var _sent: [SentBatch] = []
    private var _adServicesCalls = 0
    private let adServices: (@Sendable () -> (Int, Data))?

    init(statuses: [Int] = [], adServices: (@Sendable () -> (Int, Data))? = nil) {
        self.statuses = statuses
        self.adServices = adServices
    }

    var sent: [SentBatch] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    var adServicesCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _adServicesCalls
    }

    var allEvents: [[String: Any]] { sent.flatMap(\.events) }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let status = try respond(request)
        return status
    }

    private func respond(_ request: URLRequest) throws -> (status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        if request.url?.host == "api-adservices.apple.com" {
            _adServicesCalls += 1
            return adServices?() ?? (404, Data())
        }
        let raw = request.httpBody ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        _sent.append(SentBatch(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], raw: raw, body: body))
        let status = statuses.isEmpty ? 202 : statuses.removeFirst()
        if status == -1 { throw OfflineError() }
        return (status, Data())
    }
}

final class FakeNative: NativeBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [(Int, CoarseValue)] = []
    let token: String?

    init(token: String? = nil) {
        self.token = token
    }

    var updates: [(Int, CoarseValue)] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }

    func adServicesToken() async -> String? { token }

    func updateConversionValue(fine: Int, coarse: CoarseValue, lockWindow: Bool) async {
        record(fine, coarse)
    }

    private func record(_ fine: Int, _ coarse: CoarseValue) {
        lock.lock()
        _updates.append((fine, coarse))
        lock.unlock()
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000_000

    var now: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ ms: Int64) {
        lock.lock()
        value += ms
        lock.unlock()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

struct Harness {
    let storage = MemoryStorage()
    let transport: FakeTransport
    let clock = TestClock()
    let ids = Counter()
    var native: FakeNative?
    var launchURL: String? = "myapp://open?aky_c=launch"
    var launchedInBackground = false

    init(statuses: [Int] = [], adServices: (@Sendable () -> (Int, Data))? = nil, native: FakeNative? = nil) {
        transport = FakeTransport(statuses: statuses, adServices: adServices)
        self.native = native
    }

    func make(_ configure: (inout AppeekyOptions) -> Void = { _ in }) -> AppeekyCore {
        var options = AppeekyOptions(key: "apk_test", endpoint: URL(string: "https://analytics.test/v1/ingest")!, flushAt: 1_000)
        configure(&options)
        let clock = clock
        let ids = ids
        let launchURL = launchURL
        let deps = CoreDependencies(
            storage: storage,
            transport: transport,
            native: native,
            now: { clock.now },
            randomId: { "id\(ids.next())" },
            deviceContext: { DeviceContext(platform: "ios", osVersion: "18.1", locale: "tr-TR") },
            launchURL: { launchURL },
            sleep: { _ in await Task.yield() },
            startInterval: { _, _ in {} },
            log: { _ in },
            launchedInBackground: launchedInBackground
        )
        return AppeekyCore(config: AppeekyCore.Config(options), deps: deps)
    }
}
