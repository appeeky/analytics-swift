import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    /// App version, build, OS version, hardware model and locale of this device.
    static func current() -> DeviceContext {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { osVersion += ".\(os.patchVersion)" }
        #if os(iOS)
        let platform: String? = "ios"
        #else
        let platform: String? = nil
        #endif
        return DeviceContext(
            platform: platform,
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            osVersion: osVersion,
            deviceModel: hardwareModel(),
            locale: bcp47Locale()
        )
    }

    /// `iPhone16,2`; on the simulator, the simulated device's identifier.
    static func hardwareModel() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }

    /// `tr_TR@calendar=gregorian` → `tr-TR`.
    static func bcp47Locale(_ locale: Locale = .current) -> String? {
        let base = locale.identifier.split(separator: "@").first.map(String.init) ?? locale.identifier
        let tag = base.replacingOccurrences(of: "_", with: "-")
        return tag.isEmpty ? nil : tag
    }
}
