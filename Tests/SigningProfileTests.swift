import Foundation

/// Reading HealthKit out of a provisioning profile — the in-app diagnosis
/// for sideloaded installs that can't connect Apple Health.
func runSigningProfileTests() {
    func envelope(_ entitlements: String) -> Data {
        // Binary junk either side, like the real CMS envelope.
        var data = Data([0x30, 0x82, 0x1f, 0x00, 0xff, 0xfe])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>TeamName</key><string>Jane Appleseed</string>
        <key>CreationDate</key><date>2026-11-17T05:00:00Z</date>
        <key>Entitlements</key><dict>\(entitlements)</dict>
        </dict></plist>
        """.utf8))
        data.append(Data([0x00, 0xa0, 0x82, 0x0d]))
        return data
    }
    let created = ISO8601DateFormatter().date(from: "2026-11-17T05:00:00Z")!

    let with = SigningProfile.parse(envelope("<key>com.apple.developer.healthkit</key><true/><key>get-task-allow</key><true/>"))
    expect(with?.includesHealthKit == true, "a profile with the HealthKit entitlement is recognised")
    expect(with?.teamName == "Jane Appleseed" && with?.created == created, "team and creation date are read")

    let without = SigningProfile.parse(envelope("<key>get-task-allow</key><true/>"))
    expect(without?.includesHealthKit == false, "a profile without it is recognised")
    expect(SigningProfile.parse(envelope("<key>com.apple.developer.healthkit</key><false/>"))?.includesHealthKit == false,
           "HealthKit set to false counts as absent")
    expect(SigningProfile.parse(Data("not a profile".utf8)) == nil, "junk is not a profile")
    expect(SigningProfile.parse(Data()) == nil, "empty data is not a profile")

    let soon = created.addingTimeInterval(5 * 60)
    expect(SigningProfile.healthKitDiagnosis(without, now: soon).contains("does NOT include HealthKit"),
           "the diagnosis says when Apple's profile lacks HealthKit")
    expect(SigningProfile.healthKitDiagnosis(without, now: soon).contains("issued 5 min ago"), "and how fresh the profile is")
    expect(SigningProfile.healthKitDiagnosis(with, now: created.addingTimeInterval(3 * 86400)).contains("DOES include HealthKit")
           && SigningProfile.healthKitDiagnosis(with, now: created.addingTimeInterval(3 * 86400)).contains("3 days ago"),
           "the diagnosis says when the profile has it and the signature doesn't")
    expect(SigningProfile.healthKitDiagnosis(nil).contains("no signing profile"), "no profile is reported as such")

    print("Signing profile checks passed")
}
