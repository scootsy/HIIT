import SwiftUI

/// The machine capability questions, shared by first-run setup and the
/// Settings editor so the two screens can never drift apart — they used to be
/// two hand-maintained copies of the same ~45 lines.
struct MachineProfileForm: View {
    let equipment: Equipment
    @Binding var machine: MachineProfile
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if equipment == .treadmill {
            Section("Speed") {
                VStack(alignment: .leading) {
                    Text("Top speed you'd ever use: \(settings.speedString(machine.maxSpeedMph))")
                        .font(.subheadline)
                    Slider(value: $machine.maxSpeedMph, in: 5...15, step: 0.5)
                }
                Picker("Speed buttons react", selection: $machine.cueLeadSeconds) {
                    Text("Fast (5s warning)").tag(5)
                    Text("Normal (10s warning)").tag(10)
                    Text("Slow (15s warning)").tag(15)
                }
            }
            Section("Incline") {
                Toggle("Has incline", isOn: $machine.hasIncline)
                if machine.hasIncline {
                    VStack(alignment: .leading) {
                        Text("Max incline: \(Int(machine.maxInclinePercent))%")
                            .font(.subheadline)
                        Slider(value: $machine.maxInclinePercent, in: 4...15, step: 1)
                    }
                }
            }
        } else {
            Section("Resistance") {
                Picker("Resistance levels on your bike", selection: $machine.maxResistance) {
                    Text("8").tag(8)
                    Text("10").tag(10)
                    Text("16").tag(16)
                    Text("20").tag(20)
                    Text("24").tag(24)
                    Text("32").tag(32)
                    Text("100 (Peloton-style)").tag(100)
                }
            }
        }
    }
}
