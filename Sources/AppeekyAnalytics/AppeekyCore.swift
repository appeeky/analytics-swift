import Foundation

let stateKey = "state"
let queueKey = "queue"
private let maxBatch = 100
private let maxBackoffMs: Int64 = 5 * 60 * 1000
private let attributionTimeoutMs: Int64 = 3_000
/// A single foreground stretch longer than this is clamped (clock jumps, stuck timers).
private let maxForegroundMs: Int64 = 4 * 60 * 60 * 1000
let adServicesURL = URL(string: "https://api-adservices.apple.com/api/v1/")!
/// Apple may answer 404 until the attribution record is ready.
private let adServicesAttempts = 3
private let adServicesRetryMs: Int64 = 5_000
private let dayMs: Int64 = 24 * 60 * 60 * 1000

// Conversion value schema; keep in step with packages/core/src/skan.ts.
let conversionOpened = 1
let conversionReturned = 2
let conversionTrial = 8
let conversionPurchaseBase = 16

func purchaseFineValue(_ valueUsd: Double) -> Int {
    min(63, conversionPurchaseBase + Int((valueUsd / 2).rounded(.down)))
}

func coarseFor(_ fine: Int) -> CoarseValue {
    fine >= conversionPurchaseBase ? .high : fine >= conversionReturned ? .medium : .low
}

/// The opening URL when it came from an Appeeky smart link (`aky_l=`).
/// (Android also reads `aky_dl` from the Play referrer; iOS has no referrer.)
func deferredDeepLinkFrom(installReferrer: String?, openURL: String?) -> String? {
    if let installReferrer,
       let dl = URLComponents(string: "?" + installReferrer)?.queryItems?.first(where: { $0.name == "aky_dl" })?.value,
       !dl.isEmpty {
        return dl
    }
    if let openURL, openURL.range(of: "[?&]aky_l=", options: .regularExpression) != nil { return openURL }
    return nil
}

private let eventNamePattern = "^[A-Za-z0-9_.:-]+$"

/// Platform-independent client: install id, sessions, offline queue, batching
/// and retries. Mirrors packages/sdk-expo/src/core.ts. ``Appeeky`` wires it to
/// UIKit, the file system and URLSession; tests inject fakes.
actor AppeekyCore {
    struct Config: Sendable {
        var key: String
        var endpoint: URL
        var flushIntervalMs: Int64
        var flushAt: Int
        var maxQueueSize: Int
        var sessionTimeoutMs: Int64
        var resolveAdServicesOnDevice: Bool
        var adServicesToken: (@Sendable () async -> String?)?
        var context: DeviceContext?
        var disabled: Bool
        var debug: Bool

        init(_ options: AppeekyOptions) {
            key = options.key
            endpoint = options.endpoint
            flushIntervalMs = Int64(options.flushInterval * 1000)
            flushAt = options.flushAt
            maxQueueSize = options.maxQueueSize
            sessionTimeoutMs = Int64(options.sessionTimeout * 1000)
            resolveAdServicesOnDevice = options.resolveAdServicesOnDevice
            adServicesToken = options.adServicesToken
            context = options.context
            disabled = options.disabled
            debug = options.debug
        }
    }

    private let config: Config
    private let deps: CoreDependencies
    /// Known from the first moment, so the app can read it synchronously.
    nonisolated let installId: String

    private var state: PersistedState
    private let isNewInstall: Bool
    private var booted = false
    private var queue: [QueuedEvent]
    private var attribution: Attribution?
    private var context = DeviceContext()
    private var bootTask: Task<Void, Never>?
    /// Resolves once first-launch attribution is collected; batches wait for it.
    private var attributionTask: Task<Void, Never>?
    /// Resolves once the in-app destination of the opening smart link is known.
    private var deepLinkTask: Task<Void, Never>?
    /// In-app destination from the smart link that brought this install, if any.
    private var deferredDeepLink: String?
    private var flushTask: Task<Void, Never>?
    /// Native conversion value updates run one after another, in order.
    private var conversionTask: Task<Void, Never>?
    private var cancelTimer: CancelHandle?
    private var backoffMs: Int64 = 0
    private var retryAt: Int64 = 0
    /// When the app last came to the foreground; nil while in the background.
    private var foregroundSince: Int64?
    /// Launched in the background: first_open waits for the first foreground.
    private var pendingFirstOpen = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    init(config: Config, deps: CoreDependencies) {
        self.config = config
        self.deps = deps
        let saved = deps.storage.read(stateKey).flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        let hasInstall = !(saved?.installId.isEmpty ?? true)
        isNewInstall = !hasInstall
        state = hasInstall ? saved! : PersistedState(installId: deps.randomId())
        installId = state.installId
        queue = deps.storage.read(queueKey).flatMap { try? JSONDecoder().decode([QueuedEvent].self, from: $0) } ?? []
    }

    // MARK: - Public surface (called through Appeeky)

    /// Records first_open on a new install and starts the first session.
    func start() async {
        if config.disabled { return }
        if bootTask == nil { bootTask = Task { self.boot() } }
        await bootTask?.value
    }

    private func boot() {
        context = deps.deviceContext().merged(with: config.context).sanitized()

        if state.attributionSent != true {
            collectAttribution()
        }

        if deps.launchedInBackground {
            pendingFirstOpen = isNewInstall
        } else {
            // Session first, so first_open carries the session id.
            ensureSession()
            foregroundSince = deps.now()
            if isNewInstall { recordFirstOpen() }
        }
        if isNewInstall { state.installedAt = deps.now() }
        persist()
        booted = true

        let interval = config.flushIntervalMs
        cancelTimer = deps.startInterval(interval) { [weak self] in await self?.flush() }
        beginFlush(force: false)
    }

    func track(_ name: String, properties: Properties? = nil, value: Double? = nil) async {
        guard await ready() else { return }
        ensureSession()
        enqueue(name, props: cleanProps(properties), value: value)
    }

    func screen(_ name: String, properties: Properties? = nil) async {
        guard await ready() else { return }
        ensureSession()
        enqueue("screen", screen: name.prefixUTF16(128), props: cleanProps(properties))
    }

    /// Ad revenue from one impression, in USD.
    func adRevenue(_ valueUsd: Double, network: String?, adUnit: String?, format: String?) async {
        guard valueUsd.isFinite, valueUsd >= 0 else { return }
        let props: Properties = [
            "network": network.map(PropValue.string) ?? .null,
            "ad_unit": adUnit.map(PropValue.string) ?? .null,
            "format": format.map(PropValue.string) ?? .null,
        ]
        await track("ad_revenue", properties: props, value: (valueUsd * 1e6).rounded() / 1e6)
    }

    /// The in-app destination of the smart link that opened the app on its
    /// first launch, once; nil afterwards or when there is none.
    func takeDeferredDeepLink() async -> String? {
        if config.disabled { return nil }
        await start()
        await deepLinkTask?.value
        guard state.deepLinkDelivered != true, let link = deferredDeepLink else { return nil }
        state.deepLinkDelivered = true
        persist()
        return link
    }

    func trialStarted() async {
        guard await ready() else { return }
        raiseConversionValue(conversionTrial)
    }

    func purchased(_ valueUsd: Double) async {
        guard valueUsd.isFinite, valueUsd >= 0 else { return }
        guard await ready() else { return }
        raiseConversionValue(purchaseFineValue(valueUsd))
    }

    /// Links this install to the RevenueCat app_user_id (or Superwall user id).
    func identify(_ userId: String?) async {
        guard await ready() else { return }
        let id = userId.flatMap { $0.isEmpty ? nil : $0.prefixUTF16(256) }
        state.userId = id
        persist()
        // The user id rides on every batch's context; this event makes sure a
        // batch goes out soon so the install is linked before the first purchase.
        enqueue(id != nil ? "identify" : "reset")
        Task {
            await self.deps.sleep(1_000)
            await self.flush()
        }
    }

    func onForeground() async {
        guard await ready() else { return }
        ensureSession()
        if foregroundSince == nil { foregroundSince = deps.now() }
        if pendingFirstOpen {
            pendingFirstOpen = false
            recordFirstOpen()
            persist()
        }
    }

    /// Marks activity, reports the time in the foreground and flushes.
    func onBackground() async {
        guard await ready() else { return }
        let now = deps.now()
        state.lastActiveAt = now
        // Time on screen since the last foreground; sessions add these up.
        if let since = foregroundSince {
            let foregroundMs = min(max(now - since, 0), maxForegroundMs)
            foregroundSince = nil
            enqueue("app_background", props: ["foreground_ms": .int(Int(foregroundMs))])
        }
        persist()
        beginFlush(force: true)
    }

    /// Sends everything queued now. Returns when the queue is empty or a send failed.
    func flush(force: Bool = false) async {
        await beginFlush(force: force)?.value
    }

    func shutdown() {
        cancelTimer?()
        cancelTimer = nil
    }

    /// Waits for in-flight sends and conversion value updates (tests, background task).
    func idle() async {
        await flushTask?.value
        await conversionTask?.value
    }

    // MARK: - Internals

    private func ready() async -> Bool {
        if config.disabled { return false }
        await start()
        return booted
    }

    private func recordFirstOpen() {
        enqueue("first_open")
        raiseConversionValue(conversionOpened)
    }

    /// SKAdNetwork fine values only go up, so a later, weaker signal never
    /// overwrites a purchase. Schema shared with the server (core/skan.ts).
    private func raiseConversionValue(_ fine: Int) {
        guard let native = deps.native else { return }
        if (state.conversionValue ?? 0) >= fine { return }
        state.conversionValue = fine
        persist()
        let coarse = coarseFor(fine)
        let previous = conversionTask
        conversionTask = Task {
            await previous?.value
            await native.updateConversionValue(fine: fine, coarse: coarse, lockWindow: false)
        }
    }

    private func collectAttribution() {
        var tokenProvider: (@Sendable () async -> String?)? = config.adServicesToken
        if tokenProvider == nil, let native = deps.native {
            tokenProvider = { await native.adServicesToken() }
        }
        let token = Task { await withTimeout(attributionTimeoutMs, tokenProvider) }
        let launchURL = Task { [deps] in await withTimeout(attributionTimeoutMs, deps.launchURL) }
        deepLinkTask = Task {
            self.deferredDeepLink = deferredDeepLinkFrom(installReferrer: nil, openURL: await launchURL.value)
        }
        attributionTask = Task {
            var collected = Attribution()
            if let adServicesToken = await token.value, !adServicesToken.isEmpty {
                collected.adServicesToken = adServicesToken
                if self.config.resolveAdServicesOnDevice, let resolved = await self.resolveAdServices(adServicesToken) {
                    collected.adServices = resolved
                }
            }
            if let url = await launchURL.value, !url.isEmpty { collected.deepLinkUrl = url.prefixUTF16(2_048) }
            self.attribution = collected
        }
    }

    private func resolveAdServices(_ token: String) async -> [String: PropValue]? {
        for attempt in 1...adServicesAttempts {
            var request = URLRequest(url: adServicesURL)
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(token.utf8)
            do {
                let (status, body) = try await deps.transport.send(request)
                if (200..<300).contains(status) {
                    return adServicesFields(body)
                }
                if status == 400 { return nil }
            } catch {
                log("AdServices request failed: \(error.localizedDescription)")
            }
            if attempt < adServicesAttempts { await deps.sleep(adServicesRetryMs) }
        }
        return nil
    }

    private func ensureSession() {
        let now = deps.now()
        let expired = state.lastActiveAt.map { now - $0 > config.sessionTimeoutMs } ?? true
        if state.sessionId == nil || expired {
            state.sessionId = deps.randomId()
            state.lastActiveAt = now
            enqueue("session_start")
            if let installedAt = state.installedAt, now - installedAt >= dayMs {
                raiseConversionValue(conversionReturned)
            }
        }
        state.lastActiveAt = now
    }

    private func enqueue(_ name: String, screen: String? = nil, props: Properties? = nil, value: Double? = nil) {
        let eventName = name.prefixUTF16(64)
        if config.debug, eventName.range(of: eventNamePattern, options: .regularExpression) == nil {
            log("event name \"\(eventName)\" may only use letters, digits, _ . : -; the server will reject its batch")
        }
        queue.append(QueuedEvent(
            id: deps.randomId(),
            name: eventName,
            ts: deps.now(),
            sessionId: state.sessionId,
            screen: screen,
            props: props,
            value: value
        ))
        if queue.count > config.maxQueueSize {
            queue.removeFirst(queue.count - config.maxQueueSize)
        }
        persistQueue()
        if queue.count >= config.flushAt { beginFlush(force: false) }
    }

    @discardableResult
    private func beginFlush(force: Bool) -> Task<Void, Never>? {
        if config.disabled || !booted { return nil }
        if let flushTask { return flushTask }
        if !force && deps.now() < retryAt { return nil }
        let task = Task {
            await self.drain()
            self.flushTask = nil
        }
        flushTask = task
        return task
    }

    private func drain() async {
        if state.attributionSent != true { await attributionTask?.value }
        while true {
            let sendAttribution = state.attributionSent != true && attribution != nil
            let batch = Array(queue.prefix(maxBatch))
            if batch.isEmpty && !sendAttribution { return }

            let body = IngestBatch(
                installId: state.installId,
                sdk: "swift/\(appeekySDKVersion)",
                context: BatchContext(context, userId: state.userId),
                attribution: sendAttribution && !(attribution?.isEmpty ?? true) ? attribution : nil,
                events: batch
            )

            var status = 0
            do {
                var request = URLRequest(url: config.endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(config.key, forHTTPHeaderField: "X-Appeeky-Key")
                request.httpBody = try encoder.encode(body)
                status = try await deps.transport.send(request).status
            } catch {
                log("batch not sent: \(error.localizedDescription)")
            }

            let retryable = status == 0 || status == 429 || status >= 500
            if retryable {
                backoffMs = min(backoffMs > 0 ? backoffMs * 2 : 5_000, maxBackoffMs)
                retryAt = deps.now() + backoffMs
                return
            }
            // 2xx: stored. Other 4xx: the server will never accept this batch,
            // so drop it rather than retrying forever.
            if status >= 400 { log("batch rejected with HTTP \(status)") }
            backoffMs = 0
            retryAt = 0
            let sent = Set(batch.map(\.id))
            queue.removeAll { sent.contains($0.id) }
            if sendAttribution {
                state.attributionSent = true
                attribution = nil
            }
            persist()
            persistQueue()
        }
    }

    private func persist() {
        if let data = try? encoder.encode(state) { deps.storage.write(stateKey, data) }
    }

    private func persistQueue() {
        if let data = try? encoder.encode(queue) { deps.storage.write(queueKey, data) }
    }

    private func log(_ message: String) {
        if config.debug { deps.log("[appeeky-analytics] \(message)") }
    }
}

/// Apple's answer, flattened to at most 20 scalar fields (strings up to 256).
func adServicesFields(_ body: Data) -> [String: PropValue] {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return [:] }
    var out: [String: PropValue] = [:]
    for key in object.keys.sorted().prefix(20) {
        switch object[key] {
        case is NSNull:
            out[key] = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out[key] = .bool(number.boolValue)
            } else if !CFNumberIsFloatType(number), let int = Int(exactly: number.int64Value) {
                out[key] = .int(int)
            } else {
                out[key] = .double(number.doubleValue)
            }
        case let text as String:
            out[key] = .string(text.prefixUTF16(256))
        default:
            continue
        }
    }
    return out
}
