import XCTest
@testable import AppeekyAnalytics

/// Mirrors packages/sdk-expo/src/core.test.ts.
final class CoreTests: XCTestCase {
    func testFirstLaunchSendsFirstOpenSessionStartAndAttributionOnce() async {
        let h = Harness()
        let sdk = h.make {
            $0.adServicesToken = { "tok" }
            $0.resolveAdServicesOnDevice = false
        }
        await sdk.start()
        await sdk.flush(force: true)

        XCTAssertEqual(h.transport.sent.count, 1)
        let first = h.transport.sent[0]
        XCTAssertEqual(first.headers["X-Appeeky-Key"], "apk_test")
        XCTAssertEqual(first.headers["Content-Type"], "application/json")
        XCTAssertEqual(first.eventNames, ["session_start", "first_open"])
        XCTAssertTrue(first.events.allSatisfy { $0["sessionId"] != nil }, "every event carries the session id")
        XCTAssertEqual(first.attribution as? [String: String], ["adServicesToken": "tok", "deepLinkUrl": "myapp://open?aky_c=launch"])
        XCTAssertEqual(first.context["locale"] as? String, "tr-TR")
        XCTAssertEqual(first.body["sdk"] as? String, "swift/\(appeekySDKVersion)")

        await sdk.screen("Paywall")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertNil(h.transport.sent[1].attribution)
        XCTAssertEqual(h.transport.sent[1].events.first?["screen"] as? String, "Paywall")
        XCTAssertEqual(h.transport.sent[1].eventNames, ["screen"])
    }

    func testRelaunchKeepsInstallIdAndSkipsFirstOpen() async {
        let h = Harness()
        let first = h.make()
        await first.start()
        await first.flush(force: true)
        await first.shutdown()

        let second = h.make()
        await second.start()
        await second.track("opened_again")
        await second.flush(force: true)
        XCTAssertEqual(second.installId, first.installId)
        let names = h.transport.sent.dropFirst().flatMap(\.eventNames)
        XCTAssertFalse(names.contains("first_open"))
        XCTAssertTrue(names.contains("opened_again"))
        // Attribution went out with the first launch only.
        XCTAssertTrue(h.transport.sent.dropFirst().allSatisfy { $0.attribution == nil })
    }

    func testKeepsQueueOnNetworkErrorsAnd5xxDropsItOn4xx() async {
        let h = Harness(statuses: [-1, 503, 202])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle() // the boot flush: offline
        await sdk.flush(force: true) // 503
        await sdk.flush(force: true) // 202
        XCTAssertEqual(h.transport.sent.count, 3)
        XCTAssertEqual(h.transport.sent[2].eventNames, ["session_start", "first_open"])
        XCTAssertEqual((h.storage.json(queueKey) as? [Any])?.count, 0)

        let rejected = Harness(statuses: [400])
        let sdk2 = rejected.make()
        await sdk2.start()
        await sdk2.flush(force: true)
        XCTAssertEqual((rejected.storage.json(queueKey) as? [Any])?.count, 0)
    }

    func testRetriesOn429() async {
        let h = Harness(statuses: [429, 202])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle() // 429
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertEqual(h.transport.sent[1].eventNames, ["session_start", "first_open"])
    }

    func testBacksOffAfterAFailureUntilForced() async {
        let h = Harness(statuses: [500])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle() // the boot flush: 500
        await sdk.flush() // within the backoff window: no request
        XCTAssertEqual(h.transport.sent.count, 1)
        h.clock.advance(6_000)
        await sdk.flush()
        XCTAssertEqual(h.transport.sent.count, 2)
    }

    func testQueueSurvivesARestartWhileOffline() async {
        let h = Harness(statuses: [-1, -1])
        let first = h.make()
        await first.start()
        await first.idle()
        await first.track("offline_event")
        await first.flush(force: true)
        await first.shutdown()
        XCTAssertEqual((h.storage.json(queueKey) as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       ["session_start", "first_open", "offline_event"])

        let second = h.make()
        await second.start()
        await second.flush(force: true)
        let delivered = h.transport.sent.last!.eventNames
        XCTAssertEqual(Array(delivered.prefix(3)), ["session_start", "first_open", "offline_event"])
        XCTAssertEqual((h.storage.json(queueKey) as? [Any])?.count, 0)
        // The first launch's attribution was never delivered, so it is collected and sent again.
        XCTAssertNotNil(h.transport.sent.last!.attribution)
    }

    func testDropsOldestEventsPastMaxQueueSize() async {
        let h = Harness(statuses: [-1])
        let sdk = h.make { $0.maxQueueSize = 3 }
        await sdk.start()
        await sdk.flush(force: true)
        for i in 1...5 { await sdk.track("e\(i)") }
        let queued = (h.storage.json(queueKey) as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(queued, ["e3", "e4", "e5"])
    }

    func testFlushesWhenFlushAtIsReached() async {
        let h = Harness()
        let sdk = h.make { $0.flushAt = 3 }
        await sdk.start()
        await sdk.flush(force: true)
        await sdk.track("a")
        await sdk.track("b")
        XCTAssertEqual(h.transport.sent.count, 1)
        await sdk.track("c")
        await sdk.idle()
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertEqual(h.transport.sent[1].eventNames, ["a", "b", "c"])
    }

    func testStartsANewSessionAfterTheTimeoutAndCarriesIdentify() async {
        let h = Harness()
        let sdk = h.make { $0.sessionTimeout = 1 }
        await sdk.start()
        await sdk.flush(force: true)
        let firstSession = h.transport.sent[0].events[0]["sessionId"] as? String

        await sdk.identify("rc_user_1")
        await sdk.onBackground()
        await sdk.idle()
        h.clock.advance(5_000)
        await sdk.onForeground()
        await sdk.track("after_resume")
        await sdk.flush(force: true)

        let last = h.transport.sent.last!
        XCTAssertEqual(last.context["userId"] as? String, "rc_user_1")
        let resumed = h.transport.allEvents.first { $0["name"] as? String == "after_resume" }
        XCTAssertNotNil(resumed)
        XCTAssertNotEqual(resumed?["sessionId"] as? String, firstSession)
        XCTAssertGreaterThanOrEqual(h.transport.allEvents.filter { $0["name"] as? String == "session_start" }.count, 2)
        XCTAssertTrue(h.transport.allEvents.contains { $0["name"] as? String == "identify" })
    }

    func testKeepsTheSessionWithinTheTimeout() async {
        let h = Harness()
        let sdk = h.make { $0.sessionTimeout = 60 }
        await sdk.start()
        await sdk.onBackground()
        h.clock.advance(30_000)
        await sdk.onForeground()
        await sdk.track("x")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.allEvents.filter { $0["name"] as? String == "session_start" }.count, 1)
    }

    func testIdentifyNilSendsResetAndClearsTheUser() async {
        let h = Harness()
        let sdk = h.make()
        await sdk.start()
        await sdk.identify("u1")
        await sdk.identify(nil)
        await sdk.flush(force: true)
        await sdk.idle()
        XCTAssertNil(h.transport.sent.last!.context["userId"])
        XCTAssertEqual(h.transport.allEvents.compactMap { $0["name"] as? String }.filter { $0 == "identify" || $0 == "reset" },
                       ["identify", "reset"])
    }

    func testDisabledSendsNothing() async {
        let h = Harness()
        let sdk = h.make { $0.disabled = true }
        await sdk.start()
        await sdk.track("x")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 0)
        XCTAssertNil(h.storage.read(stateKey))
    }

    func testExchangesTheAdServicesTokenOnDeviceAndSendsApplesAnswer() async {
        let answer = try! JSONSerialization.data(withJSONObject: ["attribution": true, "campaignId": 42, "keywordId": 7, "nested": ["x": 1]])
        let h = Harness(adServices: { (200, answer) })
        let sdk = h.make { $0.adServicesToken = { "tok" } }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.adServicesCalls, 1)
        let adServices = h.transport.sent[0].attribution?["adServices"] as? [String: Any]
        XCTAssertEqual(adServices?["attribution"] as? Bool, true)
        XCTAssertEqual(adServices?["campaignId"] as? Int, 42)
        XCTAssertEqual(adServices?["keywordId"] as? Int, 7)
        XCTAssertNil(adServices?["nested"])
        XCTAssertEqual(adServices?.count, 3)
        XCTAssertEqual(h.transport.sent[0].attribution?["adServicesToken"] as? String, "tok")
        // Booleans stay booleans in the JSON.
        XCTAssertTrue(String(decoding: h.transport.sent[0].raw, as: UTF8.self).contains("\"attribution\":true"))
    }

    func testFallsBackToOnlyTheTokenWhenAppleKeepsAnswering404() async {
        let h = Harness()
        let sdk = h.make { $0.adServicesToken = { "tok" } }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.adServicesCalls, 3)
        XCTAssertNil(h.transport.sent[0].attribution?["adServices"])
        XCTAssertEqual(h.transport.sent[0].attribution?["adServicesToken"] as? String, "tok")
    }

    func testStopsAskingAppleAfterA400() async {
        let h = Harness(adServices: { (400, Data()) })
        let sdk = h.make { $0.adServicesToken = { "tok" } }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.adServicesCalls, 1)
        XCTAssertEqual(h.transport.sent[0].attribution?["adServicesToken"] as? String, "tok")
    }

    func testUsesTheNativeBridgeTokenByDefault() async {
        let h = Harness(native: FakeNative(token: "native_tok"))
        let sdk = h.make { $0.resolveAdServicesOnDevice = false }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent[0].attribution?["adServicesToken"] as? String, "native_tok")
    }

    func testNoAttributionFieldWhenNothingWasCollected() async {
        var h = Harness()
        h.launchURL = nil
        let sdk = h.make()
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertNil(h.transport.sent[0].attribution)
        await sdk.track("x")
        await sdk.flush(force: true)
        XCTAssertEqual((h.storage.json(stateKey) as? [String: Any])?["attributionSent"] as? Bool, true)
    }

    func testAppBackgroundReportsForegroundTimeOncePerBackground() async {
        let h = Harness()
        let sdk = h.make()
        await sdk.start()
        h.clock.advance(42_000)
        await sdk.onBackground()
        await sdk.onBackground() // a second background without a foreground adds nothing
        h.clock.advance(10_000)
        await sdk.onForeground()
        h.clock.advance(5_000)
        await sdk.onBackground()
        await sdk.flush(force: true)
        await sdk.idle()
        let backgrounds = h.transport.allEvents
            .filter { $0["name"] as? String == "app_background" }
            .compactMap { ($0["props"] as? [String: Any])?["foreground_ms"] as? Int }
        XCTAssertEqual(backgrounds, [42_000, 5_000])
    }

    func testAdRevenueSendsAUSDValueAndDropsInvalidAmounts() async {
        let h = Harness()
        let sdk = h.make()
        await sdk.start()
        await sdk.adRevenue(0.0123456789, network: "admob", adUnit: nil, format: "rewarded")
        await sdk.adRevenue(-1, network: nil, adUnit: nil, format: nil)
        await sdk.adRevenue(.nan, network: nil, adUnit: nil, format: nil)
        await sdk.flush(force: true)
        let ads = h.transport.allEvents.filter { $0["name"] as? String == "ad_revenue" }
        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ads[0]["value"] as? Double, 0.012346)
        let props = ads[0]["props"] as? [String: Any]
        XCTAssertEqual(props?["network"] as? String, "admob")
        XCTAssertTrue(props?["ad_unit"] is NSNull)
    }

    func testSendsToAppeekysHostedEndpointUnlessOneIsGiven() async {
        let h = Harness()
        let sdk = h.make { $0 = AppeekyOptions(key: "apk_test", flushAt: 1_000) }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent[0].url, appeekyDefaultEndpoint)
        XCTAssertEqual(appeekyDefaultEndpoint.absoluteString, "https://ingest.appeeky.com/v1/ingest")
    }

    func testHandsTheSmartLinkThatOpenedTheAppToTheAppOnce() async {
        var h = Harness()
        h.launchURL = "myapp://offer/42?aky_c=spring&aky_l=Ab3dE9x"
        let sdk = h.make()
        let link = await sdk.takeDeferredDeepLink()
        XCTAssertEqual(link, "myapp://offer/42?aky_c=spring&aky_l=Ab3dE9x")
        let again = await sdk.takeDeferredDeepLink()
        XCTAssertNil(again)
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent[0].attribution?["deepLinkUrl"] as? String, "myapp://offer/42?aky_c=spring&aky_l=Ab3dE9x")

        // Delivered state survives a relaunch.
        let relaunched = h.make()
        let afterRelaunch = await relaunched.takeDeferredDeepLink()
        XCTAssertNil(afterRelaunch)
    }

    func testNoDeferredDeepLinkForAPlainCampaignURL() async {
        let h = Harness() // myapp://open?aky_c=launch has no aky_l
        let sdk = h.make()
        let link = await sdk.takeDeferredDeepLink()
        XCTAssertNil(link)
    }

    func testDeferredDeepLinkFromAPlayReferrer() {
        let referrer = "utm_source=appeeky&aky_c=spring&aky_l=Ab3dE9x&aky_click=c1&aky_dl=" +
            "myapp://offer/42".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(deferredDeepLinkFrom(installReferrer: referrer, openURL: nil), "myapp://offer/42")
    }

    func testRaisesTheSKAdNetworkConversionValueAndNeverLowersIt() async {
        let native = FakeNative()
        let h = Harness(native: native)
        let sdk = h.make { $0.sessionTimeout = 1 }
        await sdk.start()
        await sdk.purchased(29.99)
        await sdk.trialStarted() // lower than the purchase: ignored
        h.clock.advance(25 * 60 * 60 * 1000)
        await sdk.onForeground() // came back a day later: also lower, ignored
        await sdk.idle()
        XCTAssertEqual(native.updates.map(\.0), [1, 30])
        XCTAssertEqual(native.updates.map(\.1), [.low, .high])
        // Same schema as the server reads (packages/core/src/skan.ts).
        XCTAssertEqual(purchaseFineValue(29.99), 30)
        XCTAssertEqual(purchaseFineValue(1_000), 63)
        XCTAssertEqual((h.storage.json(stateKey) as? [String: Any])?["conversionValue"] as? Int, 30)
    }

    func testDayLaterReturnRaisesTheValueWhenNothingHigherWasSet() async {
        let native = FakeNative()
        let h = Harness(native: native)
        let sdk = h.make { $0.sessionTimeout = 1 }
        await sdk.start()
        h.clock.advance(25 * 60 * 60 * 1000)
        await sdk.onForeground()
        await sdk.idle()
        XCTAssertEqual(native.updates.map(\.0), [1, 2])
        XCTAssertEqual(native.updates.map(\.1), [.low, .medium])
    }

    func testTrialRaisesToEightWithMediumCoarse() async {
        let native = FakeNative()
        let h = Harness(native: native)
        let sdk = h.make()
        await sdk.start()
        await sdk.trialStarted()
        await sdk.trialStarted()
        await sdk.purchased(-5)
        await sdk.idle()
        XCTAssertEqual(native.updates.map(\.0), [1, 8])
        XCTAssertEqual(native.updates.map(\.1), [.low, .medium])
    }

    func testBackgroundLaunchWaitsForTheFirstForeground() async {
        var h = Harness()
        h.launchedInBackground = true
        let sdk = h.make()
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertTrue(h.transport.allEvents.isEmpty)

        h.clock.advance(60_000)
        await sdk.onForeground()
        h.clock.advance(3_000)
        await sdk.onBackground()
        await sdk.flush(force: true)
        await sdk.idle()
        XCTAssertEqual(h.transport.allEvents.compactMap { $0["name"] as? String }, ["session_start", "first_open", "app_background"])
        let background = h.transport.allEvents.last?["props"] as? [String: Any]
        XCTAssertEqual(background?["foreground_ms"] as? Int, 3_000)
    }
}
