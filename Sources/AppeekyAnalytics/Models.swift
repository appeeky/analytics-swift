import Foundation

/// Device and app fields sent with every batch. The SDK fills these in;
/// set a field in ``AppeekyOptions/context`` to override it.
public struct DeviceContext: Codable, Sendable, Equatable {
    /// `"ios"` or `"android"`.
    public var platform: String?
    public var appVersion: String?
    public var build: String?
    public var osVersion: String?
    /// Hardware identifier such as `iPhone16,2`.
    public var deviceModel: String?
    /// BCP 47 locale such as `tr-TR`.
    public var locale: String?

    public init(
        platform: String? = nil,
        appVersion: String? = nil,
        build: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        locale: String? = nil
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
    }

    /// Fields set in `override` win.
    func merged(with override: DeviceContext?) -> DeviceContext {
        guard let override else { return self }
        return DeviceContext(
            platform: override.platform ?? platform,
            appVersion: override.appVersion ?? appVersion,
            build: override.build ?? build,
            osVersion: override.osVersion ?? osVersion,
            deviceModel: override.deviceModel ?? deviceModel,
            locale: override.locale ?? locale
        )
    }

    /// Drops values the server would reject (empty after trimming, unknown
    /// platform) and shortens the rest to the server's limits.
    func sanitized() -> DeviceContext {
        func clean(_ value: String?, _ max: Int) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed.prefixUTF16(max)
        }
        return DeviceContext(
            platform: platform == "ios" || platform == "android" ? platform : nil,
            appVersion: clean(appVersion, 64),
            build: clean(build, 64),
            osVersion: clean(osVersion, 64),
            deviceModel: clean(deviceModel, 128),
            locale: clean(locale, 35)
        )
    }
}

/// Saved between launches (Application Support/AppeekyAnalytics/state.json).
struct PersistedState: Codable, Equatable {
    var installId: String
    var userId: String?
    var sessionId: String?
    var lastActiveAt: Int64?
    var attributionSent: Bool?
    /// First launch time; "came back on a later day" is measured from it.
    var installedAt: Int64?
    /// Highest SKAdNetwork fine conversion value written so far.
    var conversionValue: Int?
    /// The deferred deep link was already handed to the app.
    var deepLinkDelivered: Bool?
}

/// One queued event, in the exact shape of the ingest API's `events[]`.
struct QueuedEvent: Codable, Equatable {
    var id: String
    var name: String
    var ts: Int64
    var sessionId: String?
    var screen: String?
    var props: Properties?
    var value: Double?
}

/// First-launch attribution, in the shape of the ingest API's `attribution`.
struct Attribution: Codable, Equatable {
    var adServicesToken: String?
    /// Apple's AdServices answer when the token was exchanged on the device.
    var adServices: [String: PropValue]?
    var installReferrer: String?
    var deepLinkUrl: String?

    var isEmpty: Bool {
        adServicesToken == nil && adServices == nil && installReferrer == nil && deepLinkUrl == nil
    }
}

/// `context` of a batch: the device context plus the identified user.
struct BatchContext: Encodable {
    var platform: String?
    var appVersion: String?
    var build: String?
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var userId: String?

    init(_ context: DeviceContext, userId: String?) {
        platform = context.platform
        appVersion = context.appVersion
        build = context.build
        osVersion = context.osVersion
        deviceModel = context.deviceModel
        locale = context.locale
        self.userId = userId
    }
}

/// Body of `POST /v1/ingest` (see packages/core/src/ingest-payload.ts).
struct IngestBatch: Encodable {
    var installId: String
    var sdk: String
    var context: BatchContext
    var attribution: Attribution?
    var events: [QueuedEvent]
}
