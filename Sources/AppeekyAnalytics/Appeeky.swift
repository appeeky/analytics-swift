import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Appeeky Analytics for iOS.
///
///     Appeeky.configure(key: "apk_...")   // self-hosted: add endpoint: URL(string: "https://…/v1/ingest")
///     Appeeky.screen("Paywall")
///     Appeeky.track("onboarding_completed", properties: ["step": 3])
///     Appeeky.identify(Purchases.shared.appUserID)
///
/// Every method is safe to call from any thread. Calls are applied in the
/// order they were made.
public enum Appeeky {
    private static let holder = RuntimeHolder()

    // MARK: Setup

    /// Starts the SDK. Call once, as early as possible: in
    /// `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App.init`.
    /// Later calls are ignored until ``shutdown()``.
    public static func configure(_ options: AppeekyOptions) {
        let created = holder.setIfEmpty { Runtime(options: options) }
        if !created, options.debug {
            sdkLogger.warning("[appeeky-analytics] configure() called twice; ignored.")
        }
    }

    /// Starts the SDK with the app's publishable key (`apk_…`).
    /// - Parameters:
    ///   - endpoint: A self-hosted server's ingest URL, ending in `/v1/ingest`.
    ///     Defaults to Appeeky's hosted service.
    ///   - debug: Log rejected batches and network errors.
    public static func configure(key: String, endpoint: URL? = nil, debug: Bool = false) {
        configure(AppeekyOptions(key: key, endpoint: endpoint, debug: debug))
    }

    /// The random id of this install, kept until the app is deleted. Nil before ``configure(_:)``.
    public static var installId: String? {
        current()?.core.installId
    }

    // MARK: Events

    /// Records a screen view.
    public static func screen(_ name: String, properties: Properties? = nil) {
        submit("screen") { await $0.screen(name, properties: properties) }
    }

    /// Records one of your own events. Names may use letters, digits, `_`, `.`,
    /// `:` and `-`, up to 64 characters.
    public static func track(_ name: String, properties: Properties? = nil, value: Double? = nil) {
        submit("track") { await $0.track(name, properties: properties, value: value) }
    }

    /// Links this install to your RevenueCat `appUserID` (or the id you give
    /// Superwall) so purchases get a source. Pass nil on logout.
    public static func identify(_ userId: String?) {
        submit("identify") { await $0.identify(userId) }
    }

    /// Ad revenue from one paid impression, in USD.
    public static func adRevenue(_ valueUsd: Double, network: String? = nil, adUnit: String? = nil, format: String? = nil) {
        submit("adRevenue") { await $0.adRevenue(valueUsd, network: network, adUnit: adUnit, format: format) }
    }

    /// A trial started: raises the SKAdNetwork conversion value.
    public static func trialStarted() {
        submit("trialStarted") { await $0.trialStarted() }
    }

    /// A purchase in USD: raises the SKAdNetwork conversion value. Revenue
    /// itself comes from RevenueCat or Superwall, so nothing is counted twice.
    public static func purchased(_ valueUsd: Double) {
        submit("purchased") { await $0.purchased(valueUsd) }
    }

    /// Sends everything queued now. Returns when the queue is empty or a send failed.
    public static func flush() async {
        guard let runtime = current("flush") else { return }
        await runtime.barrier()
        await runtime.core.flush(force: true)
    }

    /// Sends everything queued now, then calls `completion` on an arbitrary thread.
    public static func flush(completion: @escaping @Sendable () -> Void) {
        Task {
            await flush()
            completion()
        }
    }

    /// The destination of the smart link that opened the app on its first
    /// launch. Returns it once, on the first launch; nil otherwise.
    public static func deferredDeepLink() async -> URL? {
        guard let runtime = current("deferredDeepLink") else { return nil }
        await runtime.barrier()
        return await runtime.core.takeDeferredDeepLink().flatMap(URL.init(string:))
    }

    /// Completion-handler variant of ``deferredDeepLink()``; `completion` runs on the main queue.
    public static func deferredDeepLink(completion: @escaping @Sendable (URL?) -> Void) {
        Task {
            let url = await deferredDeepLink()
            DispatchQueue.main.async { completion(url) }
        }
    }

    // MARK: Deep links

    /// Hand the SDK the URL that opened the app, for campaign and smart link
    /// attribution. Call it from `application(_:open:options:)`,
    /// `scene(_:openURLContexts:)` or SwiftUI's `.onOpenURL`. Safe to call
    /// before ``configure(_:)`` and for every URL; only the first one counts.
    public static func handleOpenURL(_ url: URL) {
        LaunchURLStore.shared.record(url)
    }

    /// Hand the SDK a universal link (`NSUserActivityTypeBrowsingWeb`). Call it
    /// from `application(_:continue:restorationHandler:)`,
    /// `scene(_:continue:)` or SwiftUI's `.onContinueUserActivity`.
    public static func handleUserActivity(_ userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
            LaunchURLStore.shared.record(url)
        }
    }

    #if canImport(UIKit) && os(iOS)
    /// Reads the launch URL or universal link from `didFinishLaunchingWithOptions`.
    public static func handleLaunchOptions(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        guard let launchOptions else { return }
        if let url = launchOptions[.url] as? URL {
            handleOpenURL(url)
        }
        if let activities = launchOptions[.userActivityDictionary] as? [AnyHashable: Any] {
            for case let activity as NSUserActivity in activities.values {
                handleUserActivity(activity)
            }
        }
    }

    /// Reads the launch URL or universal link from `scene(_:willConnectTo:options:)`.
    @MainActor
    public static func handleConnectionOptions(_ connectionOptions: UIScene.ConnectionOptions) {
        if let url = connectionOptions.urlContexts.first?.url {
            handleOpenURL(url)
        }
        for activity in connectionOptions.userActivities {
            handleUserActivity(activity)
        }
    }
    #endif

    /// Stops timers and lifecycle observers (tests, or switching keys).
    public static func shutdown() {
        holder.take()?.stop()
    }

    // MARK: Internals

    private static func current(_ method: String? = nil) -> Runtime? {
        let value = holder.value
        if value == nil, let method {
            sdkLogger.warning("[appeeky-analytics] \(method, privacy: .public)() called before configure(); ignored.")
        }
        return value
    }

    private static func submit(_ method: String, _ operation: @escaping @Sendable (AppeekyCore) async -> Void) {
        current(method)?.submit(operation)
    }
}

/// The configured client, guarded by a lock.
final class RuntimeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: Runtime?

    var value: Runtime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    /// Creates the runtime unless one exists; true when it was created.
    func setIfEmpty(_ make: () -> Runtime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if runtime != nil { return false }
        runtime = make()
        return true
    }

    func take() -> Runtime? {
        lock.lock()
        defer { lock.unlock() }
        let value = runtime
        runtime = nil
        return value
    }
}

/// One configured client: the core actor, an ordered queue of calls into it,
/// and the app lifecycle wiring.
final class Runtime: @unchecked Sendable {
    let core: AppeekyCore
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let consumer: Task<Void, Never>
    #if canImport(UIKit) && os(iOS)
    private var lifecycle: LifecycleObserver?
    #endif

    init(options: AppeekyOptions) {
        var deps = CoreDependencies(
            storage: FileStorage.applicationSupport(),
            transport: URLSessionTransport.make(),
            native: nil,
            now: currentTimeMs,
            randomId: { UUID().uuidString.lowercased() },
            deviceContext: { DeviceInfo.current() },
            // The scene / SwiftUI open-URL callbacks run after configure(); give them a moment.
            launchURL: { await LaunchURLStore.shared.wait(ms: 2_000)?.absoluteString },
            sleep: defaultSleep,
            startInterval: defaultStartInterval,
            log: { message in sdkLogger.warning("\(message, privacy: .public)") }
        )
        #if canImport(UIKit) && os(iOS)
        deps.native = AppleNativeBridge()
        deps.launchedInBackground = isLaunchedInBackground()
        #endif
        core = AppeekyCore(config: AppeekyCore.Config(options), deps: deps)

        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.continuation = continuation
        consumer = Task {
            for await operation in stream {
                await operation()
            }
        }

        let core = self.core
        submit { await $0.start() }

        #if canImport(UIKit) && os(iOS)
        if !options.disabled {
            lifecycle = LifecycleObserver(
                onForeground: { [weak self] in self?.submit { await $0.onForeground() } },
                onBackground: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        let backgroundTask = BackgroundTask.begin()
                        self.submit { core in
                            await core.onBackground()
                            Task {
                                await core.idle()
                                await MainActor.run { backgroundTask.end() }
                            }
                        }
                    }
                }
            )
        }
        #endif
        _ = core
    }

    func submit(_ operation: @escaping @Sendable (AppeekyCore) async -> Void) {
        let core = self.core
        continuation.yield { await operation(core) }
    }

    /// Returns once every call submitted before it has been applied.
    func barrier() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = continuation.yield({ done.resume() }) {
                done.resume()
            }
        }
    }

    func stop() {
        #if canImport(UIKit) && os(iOS)
        lifecycle?.stop()
        lifecycle = nil
        #endif
        continuation.finish()
        let core = self.core
        Task { await core.shutdown() }
    }
}
