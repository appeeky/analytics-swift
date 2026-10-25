#if os(iOS)
import AdServices
import Foundation
import StoreKit
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif

/// Apple Search Ads attribution token and SKAdNetwork / AdAttributionKit
/// conversion value updates.
struct AppleNativeBridge: NativeBridge {
    func adServicesToken() async -> String? {
        // attributionToken() is synchronous and can take a moment; keep it off the caller.
        await Task.detached(priority: .utility) { () -> String? in
            if #available(iOS 14.3, *) {
                return try? AAAttribution.attributionToken()
            }
            return nil
        }.value
    }

    func updateConversionValue(fine: Int, coarse: CoarseValue, lockWindow: Bool) async {
        let value = max(0, min(63, fine))
        // Ads served through AdAttributionKit and through SKAdNetwork each read
        // their own framework's value, so update both where available.
        #if canImport(AdAttributionKit)
        if #available(iOS 17.4, *) {
            let coarseValue: CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
            try? await Postback.updateConversionValue(value, coarseConversionValue: coarseValue, lockPostback: lockWindow)
        }
        #endif
        if #available(iOS 16.1, *) {
            let coarseValue: SKAdNetwork.CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
            try? await SKAdNetwork.updatePostbackConversionValue(value, coarseValue: coarseValue, lockWindow: lockWindow)
        } else if #available(iOS 15.4, *) {
            try? await SKAdNetwork.updatePostbackConversionValue(value)
        }
    }
}
#endif
