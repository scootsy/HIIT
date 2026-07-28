import SwiftUI
import Charts

/// Owns the engine for one session, feeds it live heart-rate samples, and
/// swaps to the summary screen when the workout ends.
struct ActiveWorkoutContainerView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(BluetoothHeartRateManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var engine: WorkoutEngine

    init(plan: WorkoutPlan) {
        _engine = State(initialValue: WorkoutEngine(plan: plan))
    }

    var body: some View {
        Group {
            if engine.state == .finished {
                SummaryView(engine: engine) { dismiss() }
            } else {
                ActiveWorkoutView(engine: engine)
            }
        }
        .onAppear {
            engine.soundOn = settings.value.soundOn
            engine.hapticsOn = settings.value.hapticsOn
            engine.maxHR = settings.maxHR
            engine.machine = settings.machine(for: engine.plan.equipment)
            engine.start()
            // Live HR priority: a paired BLE monitor streams every second;
            // Health-sourced samples (Watch workouts) back-fill when no strap.
            ble.workoutActive = true
            if let idString = settings.value.hrMonitorID, let uuid = UUID(uuidString: idString) {
                ble.connectToSaved(id: uuid, name: settings.value.hrMonitorName ?? "your monitor")
            }
            health.startHeartRateUpdates()
        }
        .onDisappear {
            ble.workoutActive = false
            ble.disconnect()
            health.stopHeartRateUpdates()
        }
        .onChange(of: ble.latestHR) { _, newValue in
            if let bpm = newValue {
                engine.recordHeartRate(bpm, at: ble.latestHRDate ?? Date(), fromBLE: true)
            }
        }
        .onChange(of: health.liveHeartRate) { _, newValue in
            if let bpm = newValue, !ble.isConnected {
                engine.recordHeartRate(bpm, at: health.liveHeartRateDate ?? Date())
            }
        }
    }
}

struct ActiveWorkoutView: View {
    let engine: WorkoutEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(BluetoothHeartRateManager.self) private var ble
    @State private var showEndConfirm = false
    @State private var adjustingPhase: AdjustTargetRequest? = nil

    struct AdjustTargetRequest: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private var phaseColor: Color {
        if engine.inOvertime { return Theme.recover }
        return engine.isWarning ? Theme.steady : Theme.color(for: engine.currentPhase.kind)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [phaseColor.opacity(0.42), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: phaseColor)

            VStack(spacing: 12) {
                header
                ring
                targetSection
                Spacer(minLength: 0)
                hrGraphCard
                controls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(engine.inOvertime ? "Finish and save?" : "End this workout?",
                            isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button(engine.inOvertime ? "Finish & save" : "End workout",
                   role: engine.inOvertime ? nil : .destructive) {
                engine.endWorkout()
            }
            Button("Keep going", role: .cancel) {}
        }
        .sheet(item: $adjustingPhase) { request in
            AdjustPastTargetSheet(engine: engine, index: request.index)
                .presentationDetents([.height(240)])
        }
    }

    // MARK: - Header: corners + interval wheel

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(clockString(engine.totalElapsed))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("Effort \(engine.workEffortsDone)/\(engine.plan.workPhaseCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(phaseColor)
                    .padding(.top, 2)
            }
            .frame(width: 74, alignment: .leading)

            intervalWheel

            VStack(alignment: .trailing, spacing: 2) {
                Text("REMAINING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(clockString(engine.totalRemaining))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if engine.inOvertime {
                    Text("+\(clockString(engine.overtimeSeconds))")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.recover)
                        .padding(.top, 2)
                }
            }
            .frame(width: 74, alignment: .trailing)
        }
    }

    /// Past above (dimmed, tappable to correct), current highlighted, next
    /// below — auto-scrolls as the workout advances.
    private var intervalWheel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    Color.clear.frame(height: 44)
                    ForEach(Array(engine.plan.phases.enumerated()), id: \.element.id) { index, phase in
                        wheelRow(index: index, phase: phase)
                            .id(phase.id)
                    }
                    Color.clear.frame(height: 44)
                }
            }
            .frame(height: 140)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
            .onAppear {
                proxy.scrollTo(engine.currentPhase.id, anchor: .center)
            }
            .onChange(of: engine.phaseIndex) { _, _ in
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(engine.currentPhase.id, anchor: .center)
                }
            }
        }
    }

    private func wheelRow(index: Int, phase: IntervalPhase) -> some View {
        let isCurrent = index == engine.phaseIndex
        let isPast = index < engine.phaseIndex
        let isNextDuringWarning = engine.isWarning && index == engine.phaseIndex + 1
        let target = engine.appliedTargets[index]
        let canCorrect = isPast && phase.kind == .work

        return Button {
            if canCorrect { adjustingPhase = AdjustTargetRequest(index: index) }
        } label: {
            HStack(spacing: 8) {
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 12)
                } else {
                    Circle()
                        .fill(Theme.color(for: phase.kind))
                        .frame(width: 7, height: 7)
                        .frame(width: 12)
                }
                Text(phase.label)
                    .font(isCurrent ? .footnote.weight(.bold) : .caption2)
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(primaryText(target))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(clockString(phase.seconds))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                if canCorrect {
                    Image(systemName: "pencil.circle")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isCurrent ? Color.white.opacity(0.14)
                    : isNextDuringWarning ? Theme.steady.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8))
            .opacity(isPast ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!canCorrect)
    }

    // MARK: - Ring

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0, to: engine.phaseProgress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: engine.phaseProgress)
            VStack(spacing: 2) {
                Text(ringTitle)
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(phaseColor)
                Text(engine.inOvertime ? "+\(clockString(engine.overtimeSeconds))" : countdownString(engine.phaseRemaining))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(ringSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 185)
        .aspectRatio(1, contentMode: .fit)
    }

    private var ringTitle: String {
        if engine.inOvertime { return "COMPLETE" }
        if engine.isWarning { return "GET READY" }
        return engine.currentPhase.kind.title.uppercased()
    }

    private var ringSubtitle: String {
        if engine.state == .paused { return "Paused" }
        if engine.inOvertime { return "Keep moving — stop when you're done" }
        return engine.currentPhase.cue
    }

    // MARK: - Target (primary metric with ±, secondary on its own line)

    private var targetSection: some View {
        VStack(spacing: 5) {
            HStack(spacing: 18) {
                if adjustable {
                    adjustButton(systemName: "minus") { engine.adjustCurrentTarget(up: false) }
                }
                Text(primaryText(engine.currentTarget))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if adjustable {
                    adjustButton(systemName: "plus") { engine.adjustCurrentTarget(up: true) }
                }
            }
            if let secondary = secondaryText(engine.currentTarget) {
                Text(secondary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            if engine.currentTargetAdjusted {
                Text("adjusted — plan was \(primaryText(engine.currentPhase.target))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func adjustButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.1), in: Circle())
                .foregroundStyle(.white)
        }
    }

    private var adjustable: Bool {
        if engine.plan.equipment == .bike {
            return engine.currentTarget.resistance != nil
        }
        return engine.currentTarget.speedMph != nil
    }

    private func primaryText(_ target: PhaseTarget) -> String {
        if engine.plan.equipment == .bike {
            if let resistance = target.resistance { return "Resistance \(resistance)" }
        } else if let speed = target.speedMph {
            return settings.speedString(speed)
        }
        return target.effortWords
    }

    private func secondaryText(_ target: PhaseTarget) -> String? {
        if engine.plan.equipment == .bike {
            if let cadence = target.cadenceRPM { return "\(cadence) rpm" }
            return nil
        }
        if engine.plan.equipment == .outdoor {
            return target.effortWords
        }
        if let incline = target.inclinePercent, incline > 0.5 {
            return String(format: "%.0f%% incline", incline)
        }
        return nil
    }

    // MARK: - Heart-rate graph

    /// Fills across the planned duration as the workout runs; the axis
    /// extends live once the session goes into overtime.
    private var hrGraphCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                if let hr = engine.latestHR, let date = engine.latestHRDate,
                   Date().timeIntervalSince(date) < 30 {
                    Text("\(Int(hr))")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    if let maxHR = engine.maxHR {
                        Text(HeartRateZone.zone(forPercent: hr / maxHR * 100).label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                } else {
                    Text("– –")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Text(engine.coachMessage.isEmpty ? hrHint : engine.coachMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if engine.hrHistory.count >= 2 {
                Chart {
                    ForEach(engine.hrHistory, id: \.date) { sample in
                        LineMark(
                            x: .value("Minutes", sample.date.timeIntervalSince(engine.startDate) / 60),
                            y: .value("BPM", sample.bpm))
                            .foregroundStyle(.red)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if engine.inOvertime {
                        RuleMark(x: .value("Planned", engine.plan.totalSeconds / 60))
                            .foregroundStyle(.white.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXScale(domain: 0...graphMaxMinutes)
                .chartYScale(domain: graphYDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 62)
            } else {
                Text("Your heart-rate curve draws here across the whole workout")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var graphMaxMinutes: Double {
        max(engine.plan.totalSeconds, engine.totalElapsed + 15) / 60
    }

    private var graphYDomain: ClosedRange<Double> {
        let values = engine.hrHistory.map { $0.bpm }
        guard let lo = values.min(), let hi = values.max() else { return 60...180 }
        return max(35, lo - 12)...(hi + 15)
    }

    private var hrHint: String {
        switch ble.status {
        case .connected(let name):
            return "Live from \(name)"
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .bluetoothOff:
            return "Bluetooth is off — your monitor can't connect"
        default:
            return "For live HR: pair a strap in Settings, or start a Watch workout"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                showEndConfirm = true
            } label: {
                Image(systemName: engine.inOvertime ? "checkmark" : "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(engine.inOvertime ? Theme.recover.opacity(0.35) : .white.opacity(0.1), in: Circle())
                    .foregroundStyle(.white)
            }
            Button {
                if engine.state == .paused {
                    engine.resume()
                } else {
                    engine.pause()
                }
            } label: {
                Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title.weight(.semibold))
                    .frame(width: 72, height: 72)
                    .background(.white.opacity(0.16), in: Circle())
                    .foregroundStyle(.white)
            }
            Button {
                engine.skip()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.1), in: Circle())
                    .foregroundStyle(.white)
            }
            .opacity(engine.inOvertime ? 0.3 : 1)
            .disabled(engine.inOvertime)
        }
        .padding(.bottom, 4)
    }
}

/// "That sprint was actually faster/slower": corrects a completed effort and
/// recalibrates the rest of the workout (and next session's starting point).
struct AdjustPastTargetSheet: View {
    let engine: WorkoutEngine
    let index: Int
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(engine.plan.phases[index].label)
                .font(.headline)
            HStack(spacing: 24) {
                Button {
                    engine.adjustTarget(phaseAt: index, up: false)
                } label: {
                    Image(systemName: "minus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                Text(currentText)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 120)
                Button {
                    engine.adjustTarget(phaseAt: index, up: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 46, height: 46)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
            }
            Text("What did you actually do? This corrects the record and updates the rest of today's efforts — and where next session starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
        }
        .padding(20)
    }

    private var currentText: String {
        let target = engine.appliedTargets[index]
        if engine.plan.equipment == .bike {
            if let resistance = target.resistance { return "Resistance \(resistance)" }
        } else if let speed = target.speedMph {
            return settings.speedString(speed)
        }
        return target.effortWords
    }
}
