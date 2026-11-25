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
        // first_open is never evicted before an ordinary event.
        XCTAssertEqual(queued(h), ["first_open", "e4", "e5"])
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

    func testIdentifyWithTheSameIdDoesNothing() async {
        let h = Harness()
        let first = h.make()
        await first.start()
        await first.identify("u1")
        await first.flush(force: true)
        await first.idle()
        let sentBefore = h.transport.sent.count
        let queueBefore = h.storage.read(queueKey)

        await first.identify("u1")
        await first.idle()
        await first.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, sentBefore, "no event, so nothing to send")
        XCTAssertEqual(h.storage.read(queueKey), queueBefore)
        await first.shutdown()

        // The next launch calls identify() again with the persisted id.
        let second = h.make()
        await second.start()
        await second.identify("u1")
        await second.identify("")
        await second.identify("u2")
        await second.flush(force: true)
        await second.idle()
        XCTAssertEqual(h.transport.allEvents.compactMap { $0["name"] as? String }.filter { $0 == "identify" || $0 == "reset" },
                       ["identify", "reset", "identify"])
        XCTAssertEqual(h.transport.sent.last!.context["userId"] as? String, "u2")
    }

    func testIdentifyNilWithoutAUserDoesNothing() async {
        let h = Harness()
        let sdk = h.make()
        await sdk.start()
        await sdk.identify(nil)
        await sdk.flush(force: true)
        await sdk.idle()
        XCTAssertFalse(h.transport.allEvents.contains { $0["name"] as? String == "reset" })
    }

    func testTestDeviceIsSentOnlyWhenTrue() async {
        let production = Harness()
        let sdk = production.make()
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertNil(production.transport.sent[0].context["testDevice"])

        var debugBuild = Harness()
        debugBuild.testDevice = true
        let sdk2 = debugBuild.make()
        await sdk2.start()
        await sdk2.flush(force: true)
        XCTAssertEqual(debugBuild.transport.sent[0].context["testDevice"] as? Bool, true)
    }

    func testTestDeviceOptionOverridesDetection() async {
        var debugBuild = Harness()
        debugBuild.testDevice = true
        let off = debugBuild.make { $0.testDevice = false }
        await off.start()
        await off.flush(force: true)
        XCTAssertNil(debugBuild.transport.sent[0].context["testDevice"], "false is left out, never sent")

        let production = Harness()
        let on = production.make { $0.testDevice = true }
        await on.start()
        await on.flush(force: true)
        XCTAssertEqual(production.transport.sent[0].context["testDevice"] as? Bool, true)

        let viaContext = Harness()
        let sdk = viaContext.make { $0.context = DeviceContext(testDevice: true) }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(viaContext.transport.sent[0].context["testDevice"] as? Bool, true)
    }

    func testPlatformMismatchWarningIsLoggedOncePerLaunchOnATestDevice() async {
        let body = Data(#"{"accepted":2,"warnings":["platform_mismatch","something_new",7]}"#.utf8)
        var h = Harness(ingestBody: body)
        h.testDevice = true
        let sdk = h.make()
        await sdk.start()
        await sdk.flush(force: true)
        await sdk.track("again")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertEqual(h.logs.lines, [
            "[appeeky-analytics] this key belongs to an app on the other store. Use the iOS app's key in the iOS build and the Android app's key in the Android build; until then both platforms are mixed in one app's reports.",
        ])
    }

    func testServerWarningsNeedDebugOrATestDevice() async {
        let body = Data(#"{"warnings":["platform_mismatch"]}"#.utf8)
        let quiet = Harness(ingestBody: body)
        let sdk = quiet.make()
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual(quiet.logs.lines, [])

        // With debug on, and on the quota answer too.
        let debug = Harness(statuses: [402], ingestBody: body)
        let sdk2 = debug.make { $0.debug = true }
        await sdk2.start()
        await sdk2.flush(force: true)
        XCTAssertEqual(debug.logs.lines.filter { $0.contains("other store") }.count, 1)

        // A rejected batch's body is not read.
        let rejected = Harness(statuses: [400], ingestBody: body)
        let sdk3 = rejected.make { $0.debug = true }
        await sdk3.start()
        await sdk3.flush(force: true)
        XCTAssertFalse(rejected.logs.lines.contains { $0.contains("other store") })
    }

    func testServerWarningsAreParsedDefensively() {
        XCTAssertEqual(serverWarnings(Data()), [])
        XCTAssertEqual(serverWarnings(Data("not json".utf8)), [])
        XCTAssertEqual(serverWarnings(Data("[1]".utf8)), [])
        XCTAssertEqual(serverWarnings(Data(#"{"accepted":1}"#.utf8)), [])
        XCTAssertEqual(serverWarnings(Data(#"{"warnings":"platform_mismatch"}"#.utf8)), [])
        XCTAssertEqual(serverWarnings(Data(#"{"warnings":["a",1,null,"b"]}"#.utf8)), ["a", "b"])
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

    private func queued(_ h: Harness) -> [String] {
        (h.storage.json(queueKey) as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    private func state(_ h: Harness) -> [String: Any] {
        h.storage.json(stateKey) as? [String: Any] ?? [:]
    }

    func testPastTheQuotaTheInstallIsDeliveredAndOtherEventsWaitInTheQueue() async {
        let h = Harness(statuses: [402, 402, 202])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle() // the boot flush: 402
        // The server stored the install, its attribution and first_open.
        XCTAssertEqual(h.transport.sent.count, 1)
        XCTAssertNotNil(h.transport.sent[0].attribution)
        XCTAssertEqual(queued(h), ["session_start"])
        XCTAssertEqual(state(h)["attributionSent"] as? Bool, true)

        // While waiting, only critical events go out, without the attribution.
        await sdk.screen("Paywall")
        await sdk.adRevenue(0.02, network: nil, adUnit: nil, format: nil)
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertEqual(h.transport.sent[1].eventNames, ["ad_revenue"])
        XCTAssertNil(h.transport.sent[1].attribution)
        XCTAssertEqual(queued(h), ["session_start", "screen"])

        // Nothing ordinary is sent before the wait is over, even when forced.
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)

        h.clock.advance(16 * 60 * 1000)
        await sdk.flush()
        XCTAssertEqual(h.transport.sent.count, 3)
        XCTAssertEqual(h.transport.sent[2].eventNames, ["session_start", "screen"])
        XCTAssertEqual(queued(h), [])
    }

    func testASecondQuotaAnswerDoublesTheWaitAndKeepsTheQueue() async {
        let h = Harness(statuses: [402, 402, 402])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle()
        h.clock.advance(16 * 60 * 1000)
        await sdk.flush()
        XCTAssertEqual(h.transport.sent.count, 2)
        h.clock.advance(16 * 60 * 1000) // the wait is 30 minutes now
        await sdk.flush()
        XCTAssertEqual(h.transport.sent.count, 2)
        h.clock.advance(15 * 60 * 1000)
        await sdk.flush()
        XCTAssertEqual(h.transport.sent.count, 3)
        XCTAssertEqual(queued(h), ["session_start"])
    }

    func testARejectedBatchDoesNotGiveUpTheAttributionAtOnce() async {
        let h = Harness(statuses: [400, 202])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle() // the boot flush: 400
        XCTAssertEqual(h.transport.sent.count, 1)
        XCTAssertEqual(queued(h), [])
        XCTAssertNotEqual(state(h)["attributionSent"] as? Bool, true)
        XCTAssertEqual(state(h)["attributionRejects"] as? Int, 1)

        await sdk.screen("Home")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 2)
        XCTAssertEqual(h.transport.sent[1].attribution as? [String: String], ["deepLinkUrl": "myapp://open?aky_c=launch"])
        XCTAssertEqual(state(h)["attributionSent"] as? Bool, true)
        XCTAssertNil(state(h)["attributionRejects"])
    }

    func testTheAttributionIsGivenUpAfterThreeRejectedBatches() async {
        let h = Harness(statuses: [400, 400, 400, 202])
        let sdk = h.make()
        await sdk.start()
        await sdk.idle()
        for name in ["a", "b"] {
            await sdk.track(name)
            await sdk.flush(force: true)
        }
        XCTAssertEqual(h.transport.sent.count, 3)
        XCTAssertEqual(state(h)["attributionSent"] as? Bool, true)
        await sdk.track("c")
        await sdk.flush(force: true)
        XCTAssertEqual(h.transport.sent.count, 4)
        XCTAssertNil(h.transport.sent[3].attribution)
    }

    func testAFullQueueEvictsOrdinaryEventsBeforeFirstOpenAndAdRevenue() async {
        let h = Harness(statuses: [-1])
        let sdk = h.make { $0.maxQueueSize = 3 }
        await sdk.start()
        await sdk.idle() // offline: session_start and first_open stay queued
        await sdk.adRevenue(0.01, network: nil, adUnit: nil, format: nil)
        await sdk.screen("A")
        await sdk.screen("B")
        XCTAssertEqual(queued(h), ["first_open", "ad_revenue", "screen"])
    }

    func testOverLongAttributionValuesAreCutToTheServersLimits() async {
        var h = Harness()
        h.launchURL = "myapp://open?aky_c=" + String(repeating: "x", count: 3_000)
        let sdk = h.make {
            $0.adServicesToken = { String(repeating: "t", count: 4_097) }
            $0.resolveAdServicesOnDevice = false
        }
        await sdk.start()
        await sdk.flush(force: true)
        XCTAssertEqual((h.transport.sent[0].attribution?["deepLinkUrl"] as? String)?.utf16.count, 2_048)
        // A token over the limit would reject the batch, so it is left out.
        XCTAssertNil(h.transport.sent[0].attribution?["adServicesToken"])
        XCTAssertEqual(h.transport.adServicesCalls, 0)
    }
}
