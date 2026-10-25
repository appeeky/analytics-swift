import Foundation

/// Version of this SDK; sent as `sdk: "swift/<version>"` with every batch.
public let appeekySDKVersion = "0.1.0"

/// Appeeky's hosted ingest endpoint; self-hosted servers pass their own.
public let appeekyDefaultEndpoint = URL(string: "https://ingest.appeeky.com/v1/ingest")!

/// Settings for ``Appeeky/configure(_:)``.
public struct AppeekyOptions: Sendable {
    /// Publishable key of the app (starts with `apk_`).
    public var key: String
    /// Ingest URL. Defaults to Appeeky's hosted service; a self-hosted server
    /// passes its own, e.g. `https://analytics.example.com/v1/ingest`.
    public var endpoint: URL
    /// Flush at least this often while the app is open. Default 10 seconds.
    public var flushInterval: TimeInterval
    /// Flush as soon as this many events are queued. Default 20.
    public var flushAt: Int
    /// Oldest events are dropped past this many queued events. Default 1000.
    public var maxQueueSize: Int
    /// A new session starts after this much time in the background. Default 30 minutes.
    public var sessionTimeout: TimeInterval
    /// Exchange the AdServices token with Apple from the device (default true).
    /// The token is sent too, so the server can still try if this fails.
    public var resolveAdServicesOnDevice: Bool
    /// Replaces the built-in `AAAttribution.attributionToken()` call.
    public var adServicesToken: (@Sendable () async -> String?)?
    /// Override or fill in device context fields.
    public var context: DeviceContext?
    /// Collect nothing and send nothing (e.g. the user opted out).
    public var disabled: Bool
    /// Log rejected batches and network errors.
    public var debug: Bool

    public init(
        key: String,
        endpoint: URL? = nil,
        flushInterval: TimeInterval = 10,
        flushAt: Int = 20,
        maxQueueSize: Int = 1_000,
        sessionTimeout: TimeInterval = 30 * 60,
        resolveAdServicesOnDevice: Bool = true,
        adServicesToken: (@Sendable () async -> String?)? = nil,
        context: DeviceContext? = nil,
        disabled: Bool = false,
        debug: Bool = false
    ) {
        self.key = key
        self.endpoint = endpoint ?? appeekyDefaultEndpoint
        self.flushInterval = flushInterval
        self.flushAt = flushAt
        self.maxQueueSize = maxQueueSize
        self.sessionTimeout = sessionTimeout
        self.resolveAdServicesOnDevice = resolveAdServicesOnDevice
        self.adServicesToken = adServicesToken
        self.context = context
        self.disabled = disabled
        self.debug = debug
    }
}
