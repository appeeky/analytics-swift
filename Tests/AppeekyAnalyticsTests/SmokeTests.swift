import XCTest
@testable import AppeekyAnalytics

/// Sends real batches through URLSession to a running server. Skipped unless
/// APPEEKY_SMOKE_ENDPOINT (…/v1/ingest) and APPEEKY_SMOKE_KEY (apk_…) are set:
///
///     APPEEKY_SMOKE_ENDPOINT=http://localhost:8817/v1/ingest APPEEKY_SMOKE_KEY=apk_… \
///       swift test --filter SmokeTests
///
/// Writes the install id to APPEEKY_SMOKE_OUT (when set) so a script can check
/// the server's users API afterwards.
final class SmokeTests: XCTestCase {
    func testSendsRealBatches() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["APPEEKY_SMOKE_ENDPOINT"].flatMap(URL.init(string:)), let key = env["APPEEKY_SMOKE_KEY"] else {
            throw XCTSkip("APPEEKY_SMOKE_ENDPOINT / APPEEKY_SMOKE_KEY not set")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appeeky-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeCore() -> AppeekyCore {
            let deps = CoreDependencies(
                storage: FileStorage(directory: dir),
                transport: URLSessionTransport.make(),
                native: nil,
                now: currentTimeMs,
                randomId: { UUID().uuidString.lowercased() },
                deviceContext: {
                    DeviceInfo.current().merged(with: DeviceContext(platform: "ios", appVersion: "1.0.0", build: "7", osVersion: "18.1", deviceModel: "iPhone16,2"))
                },
                launchURL: { "smokeapp://open?aky_c=swift-smoke&utm_source=newsletter" },
                sleep: defaultSleep,
                startInterval: defaultStartInterval,
                log: { print($0) }
            )
            var options = AppeekyOptions(key: key, endpoint: endpoint, debug: true)
            options.resolveAdServicesOnDevice = false
            return AppeekyCore(config: AppeekyCore.Config(options), deps: deps)
        }

        let sdk = makeCore()
        await sdk.start()
        await sdk.screen("Onboarding")
        await sdk.screen("Paywall", properties: ["variant": "b"])
        await sdk.track("export", properties: ["format": "pdf", "pages": 3, "shared": true], value: 2)
        await sdk.identify("rc_smoke_user")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await sdk.onBackground()
        await sdk.flush(force: true)
        await sdk.idle()
        await sdk.shutdown()

        let queued = try JSONSerialization.jsonObject(with: XCTUnwrap(FileStorage(directory: dir).read(queueKey))) as? [Any]
        XCTAssertEqual(queued?.count, 0, "the server accepted every batch")

        // Relaunch: same install, no second first_open, attribution not sent again.
        let relaunched = makeCore()
        XCTAssertEqual(relaunched.installId, sdk.installId)
        await relaunched.start()
        await relaunched.onForeground()
        await relaunched.track("opened_again")
        await relaunched.flush(force: true)
        await relaunched.idle()
        await relaunched.shutdown()
        let after = try JSONSerialization.jsonObject(with: XCTUnwrap(FileStorage(directory: dir).read(queueKey))) as? [Any]
        XCTAssertEqual(after?.count, 0)

        print("SMOKE installId=\(sdk.installId)")
        if let out = env["APPEEKY_SMOKE_OUT"] {
            try Data(sdk.installId.utf8).write(to: URL(fileURLWithPath: out))
        }
    }
}
