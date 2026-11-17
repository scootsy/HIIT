// Checks that the patched SideSign really asks Apple for the HealthKit
// capability. Compiled together with SideSign's own Feature.swift,
// Entitlement.swift, Team.swift and Account.swift (all plain Foundation), so
// it runs in seconds, before the long SideStore build starts:
//
//   swiftc -swift-version 5 -o check-healthkit \
//     $SIGN/Feature.swift $SIGN/Entitlement.swift $SIGN/Team.swift $SIGN/Account.swift \
//     scripts/sidestore-healthkit/check/main.swift && ./check-healthkit
import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String) {
    if ok {
        print("ok   - \(message)")
    } else {
        print("FAIL - \(message)")
        failures += 1
    }
}

// The capability Apple's developer portal calls HealthKit.
check(Feature.healthKit.rawValue == "HK421J6T7P", "HealthKit capability id is HK421J6T7P")

// An app that declares the HealthKit entitlement now asks for that capability…
check(Feature(entitlement: .healthKit) == .healthKit, "com.apple.developer.healthkit maps to the HealthKit capability")
// …including through the plain-string form SideStore calls.
check(Feature(entitlement: Entitlement("com.apple.developer.healthkit")) == .healthKit,
      "the string form SideStore uses maps too")

// Clinical Health Records needs Apple's special approval; it stays unrequested.
check(Feature(entitlement: Entitlement("com.apple.developer.healthkit.access")) == nil,
      "the clinical-records entitlement is still not requested")

// Both kinds of Apple account may request it (Apple's own capability table
// lists HealthKit for free accounts).
check(Feature.freeFeatures == [.appGroups, .interAppAudio, .healthKit],
      "a free account may request App Groups, Inter-App Audio and HealthKit")
check(Feature.paidFeatures.contains(.healthKit), "a paid account may request HealthKit")
check(TeamType.free.allowedFeatures?.contains(.healthKit) == true, "SideStore's free-team lookup includes HealthKit")
check(TeamType.individual.allowedFeatures?.contains(.healthKit) == true, "SideStore's paid-team lookup includes HealthKit")
check(TeamType.unknown.allowedFeatures == nil, "an unknown account type still allows nothing")
check(Entitlement.freeEntitlements.contains(.healthKit), "the entitlement list offered to free accounts includes HealthKit")

// Nothing that worked before changed.
check(Feature(entitlement: .appGroups) == .appGroups, "App Groups still map")
check(Feature(entitlement: .interAppAudio) == .interAppAudio, "Inter-App Audio still maps")
check(Feature(entitlement: .increasedMemoryLimit) == .increasedMemoryLimit, "Increased Memory Limit still maps")
check(Feature(entitlement: .getTaskAllow) == nil, "get-task-allow is still not a capability")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
