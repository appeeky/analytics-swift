import XCTest
@testable import AppeekyAnalytics

/// The batch the SDK sends must match packages/core/src/ingest-payload.ts
/// exactly: the server's schema is strict and rejects unknown keys.
final class PayloadTests: XCTestCase {
    private static let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func fixture() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixturesDir.appendingPathComponent("ingest-batch.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func roundTrip<T: Codable>(_ type: T.Type, _ object: Any) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(type, from: data)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
    }

    /// Every fixture field survives decoding into the SDK's models and encoding back.
    func testModelsUseTheServersFieldNames() throws {
        let fixture = try fixture()
        let events = try XCTUnwrap(fixture["events"] as? [Any])
        let encodedEvents = try roundTrip([QueuedEvent].self, events)
        XCTAssertEqual(encodedEvents as? NSArray, events as NSArray)

        let attribution = try XCTUnwrap(fixture["attribution"])
        XCTAssertEqual(try roundTrip(Attribution.self, attribution) as? NSDictionary, attribution as? NSDictionary)

        let context = try XCTUnwrap(fixture["context"] as? [String: Any])
        var device = try JSONDecoder().decode(DeviceContext.self, from: JSONSerialization.data(withJSONObject: context))
        device = device.sanitized()
        let batchContext = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BatchContext(device, userId: context["userId"] as? String)))
        XCTAssertEqual(batchContext as? NSDictionary, context as NSDictionary)
    }

    func testABatchFromTheClientOnlyUsesKnownKeysAndLimits() async throws {
        let answer = try JSONSerialization.data(withJSONObject: ["attribution": true, "campaignId": 42, "conversionType": "Download"])
        let h = Harness(adServices: { (200, answer) })
        let sdk = h.make { $0.adServicesToken = { "tok" } }
        await sdk.start()
        await sdk.identify("rc_user_1")
        await sdk.screen(String(repeating: "S", count: 300), properties: ["k": .string(String(repeating: "é", count: 600))])
        await sdk.track("export", properties: ["format": "pdf", "pages": 3, "ratio": 0.5, "shared": true, "folder": nil, "bad": .double(.infinity)], value: 1)
        await sdk.onBackground()
        await sdk.flush(force: true)
        await sdk.idle()

        XCTAssertFalse(h.transport.sent.isEmpty)
        for batch in h.transport.sent {
            try validate(batch.body)
        }
        dump(h.transport.sent)
    }

    func testTruncationCountsUTF16UnitsWithoutSplittingCharacters() {
        XCTAssertEqual("abc".prefixUTF16(2), "ab")
        // Each flag is 4 UTF-16 units; 5 units only fit one.
        XCTAssertEqual("🇹🇷🇹🇷".prefixUTF16(5), "🇹🇷")
        XCTAssertEqual(String(repeating: "😀", count: 300).prefixUTF16(512).utf16.count, 512)
        let props = cleanProps([String(repeating: "k", count: 100): .string(String(repeating: "😀", count: 300))])
        XCTAssertEqual(props?.keys.first?.count, 64)
        if case .string(let value)? = props?.values.first {
            XCTAssertLessThanOrEqual(value.utf16.count, 512)
        } else {
            XCTFail("expected a string")
        }
        XCTAssertNil(cleanProps([:]))
    }

    func testPropValueLiteralsAndEncoding() throws {
        let props: Properties = ["s": "x", "i": 3, "d": 0.25, "b": false, "n": nil]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(props)) as? [String: Any])
        XCTAssertEqual(json["s"] as? String, "x")
        XCTAssertEqual(json["i"] as? Int, 3)
        XCTAssertEqual(json["d"] as? Double, 0.25)
        XCTAssertEqual((json["b"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true)
        XCTAssertTrue(json["n"] is NSNull)
        let decoded = try JSONDecoder().decode(Properties.self, from: JSONEncoder().encode(props))
        XCTAssertEqual(decoded, props)
    }

    func testContextDropsValuesTheServerWouldReject() {
        let context = DeviceContext(platform: "macos", appVersion: "  ", build: "12", osVersion: "18.1",
                                    deviceModel: String(repeating: "m", count: 200), locale: "en-US")
            .sanitized()
        XCTAssertNil(context.platform)
        XCTAssertNil(context.appVersion)
        XCTAssertEqual(context.build, "12")
        XCTAssertEqual(context.deviceModel?.count, 128)
        XCTAssertEqual(DeviceInfo.bcp47Locale(Locale(identifier: "tr_TR@calendar=gregorian")), "tr-TR")
    }

    func testFileStoragePersistsBetweenInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appeeky-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        FileStorage(directory: dir).write("queue", Data("[1]".utf8))
        XCTAssertEqual(FileStorage(directory: dir).read("queue"), Data("[1]".utf8))
        XCTAssertNil(FileStorage(directory: dir).read("state"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue.json").path))
    }

    func testLaunchURLStoreKeepsTheFirstURLAndWakesWaiters() async {
        let store = LaunchURLStore()
        async let waited = store.wait(ms: 2_000)
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.record(URL(string: "myapp://a?aky_l=x")!)
        store.record(URL(string: "myapp://b")!)
        let first = await waited
        XCTAssertEqual(first?.absoluteString, "myapp://a?aky_l=x")
        XCTAssertEqual(store.current?.absoluteString, "myapp://a?aky_l=x")

        let empty = LaunchURLStore()
        let none = await empty.wait(ms: 10)
        XCTAssertNil(none)
    }

    // MARK: - Schema (ingest-payload.ts)

    private func validate(_ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(Set(body.keys).isSubset(of: ["installId", "sdk", "context", "attribution", "events"]), "\(body.keys)", file: file, line: line)
        try shortText(body["installId"], 64)
        try shortText(body["sdk"], 64)

        let context = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertTrue(Set(context.keys).isSubset(of: ["platform", "appVersion", "build", "osVersion", "deviceModel", "locale", "userId"]))
        if let platform = context["platform"] { XCTAssertTrue(["ios", "android"].contains(platform as? String)) }
        for (key, max) in [("appVersion", 64), ("build", 64), ("osVersion", 64), ("deviceModel", 128), ("locale", 35), ("userId", 256)] {
            if let value = context[key] { try shortText(value, max) }
        }

        if let attribution = body["attribution"] as? [String: Any] {
            XCTAssertTrue(Set(attribution.keys).isSubset(of: ["adServicesToken", "adServices", "installReferrer", "deepLinkUrl"]))
            if let token = attribution["adServicesToken"] { try shortText(token, 4_096) }
            if let url = attribution["deepLinkUrl"] { try shortText(url, 2_048) }
            if let adServices = attribution["adServices"] as? [String: Any] {
                XCTAssertLessThanOrEqual(adServices.count, 20)
                for value in adServices.values { try scalar(value, maxString: 256) }
            }
        } else {
            XCTAssertNil(body["attribution"])
        }

        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(events.count, 100)
        for event in events {
            XCTAssertTrue(Set(event.keys).isSubset(of: ["id", "name", "ts", "sessionId", "screen", "props", "value"]), "\(event.keys)")
            try shortText(event["id"], 64)
            let name = try XCTUnwrap(event["name"] as? String)
            XCTAssertNotNil(name.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression), name)
            let ts = try XCTUnwrap(event["ts"] as? NSNumber)
            XCTAssertFalse(CFNumberIsFloatType(ts))
            XCTAssertGreaterThan(ts.int64Value, 0)
            if let session = event["sessionId"] { try shortText(session, 64) }
            if let screen = event["screen"] { try shortText(screen, 128) }
            if let props = event["props"] as? [String: Any] {
                for value in props.values { try scalar(value, maxString: 512) }
            }
            if let value = event["value"] { XCTAssertTrue(value is NSNumber) }
        }
    }

    private func shortText(_ value: Any?, _ max: Int) throws {
        let text = try XCTUnwrap(value as? String)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertLessThanOrEqual(trimmed.utf16.count, max)
    }

    private func scalar(_ value: Any, maxString: Int) throws {
        if let text = value as? String {
            XCTAssertLessThanOrEqual(text.utf16.count, maxString)
        } else {
            XCTAssertTrue(value is NSNumber || value is NSNull, "\(type(of: value))")
        }
    }

    /// With APPEEKY_DUMP_DIR set, writes the batches so the server's own schema
    /// can check them: `npx tsx validate.ts $APPEEKY_DUMP_DIR/*.json`.
    private func dump(_ batches: [SentBatch]) {
        guard let dir = ProcessInfo.processInfo.environment["APPEEKY_DUMP_DIR"] else { return }
        for (index, batch) in batches.enumerated() {
            try? batch.raw.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swift-batch-\(index).json"))
        }
    }
}
