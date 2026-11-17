import Foundation

/// What the provisioning profile this copy of the app was installed with
/// says about HealthKit. Sideloading tools sign with whatever Apple put in
/// that profile, so when Health can't be connected this tells apart the two
/// ways it goes wrong: Apple's profile never had HealthKit (the tool didn't
/// ask for it, or Apple said no), or the profile has it and the tool dropped
/// it while signing.
struct SigningProfile: Equatable {
    var teamName: String?
    var created: Date?
    var includesHealthKit: Bool

    /// The profile embedded in the running app; nil in the simulator and
    /// for App Store installs, which carry none.
    static let embedded: SigningProfile? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }()

    /// A .mobileprovision is a signed envelope with a property list inside
    /// it in plain text; the plist is everything from `<?xml` to `</plist>`.
    static func parse(_ data: Data) -> SigningProfile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return SigningProfile(teamName: plist["TeamName"] as? String,
                              created: plist["CreationDate"] as? Date,
                              includesHealthKit: entitlements["com.apple.developer.healthkit"] as? Bool ?? false)
    }

    /// One or two sentences for the "couldn't connect Apple Health" message.
    static func healthKitDiagnosis(_ profile: SigningProfile?, now: Date = Date()) -> String {
        guard let profile else {
            return "This install has no signing profile to inspect, so it can't say where the permission was lost."
        }
        var when = ""
        if let created = profile.created {
            let minutes = Int(now.timeIntervalSince(created) / 60)
            if minutes < 120 {
                when = " (issued \(max(0, minutes)) min ago)"
            } else if minutes < 48 * 60 {
                when = " (issued \(minutes / 60) hours ago)"
            } else {
                when = " (issued \(minutes / 1440) days ago)"
            }
        }
        if profile.includesHealthKit {
            return "Diagnosis: Apple's signing profile for this install\(when) DOES include HealthKit, so the tool that signed the app left it out of the signature."
        }
        return "Diagnosis: Apple's signing profile for this install\(when) does NOT include HealthKit — the tool that installed it didn't get Apple to switch HealthKit on for this app."
    }
}
