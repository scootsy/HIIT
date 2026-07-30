import SwiftUI
import Charts

/// Owns the engine for one session, feeds it live heart-rate samples, and
/// swaps to the summary screen when the workout ends.
struct ActiveWorkoutContainerView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
    @Environment(BluetoothHeartRateManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
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
        // Observe the timestamps, not the bpm values: a steady heart rate
        // produces identical consecutive readings, and onChange never fires
        // for an unchanged value — the engine's feed would silently stall.
        .onChange(of: ble.latestHRDate) { _, newDate in
            if let bpm = ble.latestHR, let date = newDate {
                engine.recordHeartRate(bpm, at: date, fromBLE: true)
            }
        }
        .onChange(of: health.liveHeartRateDate) { _, newDate in
            if let bpm = health.liveHeartRate, let date = newDate, !ble.isConnected {
                engine.recordHeartRate(bpm, at: date)
            }
        }
        // Checkpoint the session at every phase boundary, when the app leaves
        // the foreground, and when the plan finishes — so a crash or jetsam
        // before the user taps Save can be recovered on next launch.
        .onChange(of: engine.phaseIndex) { _, _ in
            WorkoutCheckpoint.save(engine.makeCheckpoint())
        }
        .onChange(of: engine.state) { _, newState in
            if newState == .finished {
                WorkoutCheckpoint.save(engine.makeCheckpoint())
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Only while the session is live. Once it finishes, the checkpoint
            // written on the state change above is final — and once the user
            // saves, SessionSaver clears the file; re-writing it here (state
            // stays .finished on the summary screen) resurrected a phantom
            // "Recover unsaved workout?" after every save-then-lock,
            // duplicating the session and applying progression twice.
            if newPhase != .active && (engine.state == .running || engine.state == .paused) {
                WorkoutCheckpoint.save(engine.makeCheckpoint())
            }
        }
    }
}

// MARK: - Live workout

/// Layout: stats card → plan spine (expands into the effort editor during
/// recoveries) → dual-arc ring → target card → heart-rate panel → controls.
/// The amber early warning tints only the ring, the spine's current segment
/// and the target card — never the background. The whole stack lives in a
/// scroll view sized to the screen: on roomy phones nothing moves and the
/// target card floats centered between ring and heart-rate panel, while on
/// small screens (or with the effort editor open) it scrolls instead of
/// clipping the controls off the bottom edge.
struct ActiveWorkoutView: View {
    let engine: WorkoutEngine
    @Environment(SettingsStore.self) private var settings
    @State private var showEndConfirm = false
    @State private var adjustingPhase: AdjustTargetRequest? = nil
    /// nil = follow the phase (open during recoveries); true/false = user override.
    @State private var editorOverride: Bool? = nil

    struct AdjustTargetRequest: Identifiable {
        let index: Int
        var id: Int { index }
    }

    // Label + numeral styles used throughout: one numeral family, one label style.
    private static let labelFont = Font.system(size: 9.5, weight: .semibold)
    private func numerals(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// The phase colour. Overtime is green, an imminent change is amber.
    private var phaseColor: Color {
        if engine.inOvertime { return Theme.recover }
        return engine.isWarning ? Theme.warning : Theme.color(for: engine.currentPhase.kind)
    }

    /// The background tint never switches to amber — it tracks the *phase*.
    private var backgroundColor: Color {
        engine.inOvertime ? Theme.recover : Theme.color(for: engine.currentPhase.kind)
    }

    private var editorOpen: Bool {
        editorOverride ?? (engine.currentPhase.kind == .recover || engine.currentPhase.kind == .steady)
    }

    private var pastWorkIndices: [Int] {
        Array(engine.plan.phases.indices
            .filter { $0 < engine.phaseIndex && engine.plan.phases[$0].kind == .work }
            .suffix(3))
    }

    var body: some View {
        ZStack {
            Color(hex: 0x05070C).ignoresSafeArea()
            RadialGradient(colors: [backgroundColor.opacity(0.30), .clear],
                           center: .top, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: backgroundColor)

            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        statsCard
                        spine.padding(.top, 14)
                        if editorOpen, !pastWorkIndices.isEmpty { effortEditor.padding(.top, 12) }
                        ring.padding(.top, 14)
                        Spacer(minLength: 12)
                        targetCard
                        Spacer(minLength: 12)
                        hrPanel
                        controls.padding(.top, 16)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: editorOpen)
        .onChange(of: engine.phaseIndex) { _, _ in
            editorOverride = nil
        }
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

    // MARK: Stats card

    private var statsCard: some View {
        HStack(spacing: 0) {
            statBlock("REMAINING",
                      engine.inOvertime ? "+\(clockString(engine.overtimeSeconds))" : clockString(engine.totalRemaining),
                      .white)
            Divider().frame(height: 34).overlay(Color.white.opacity(0.10)).padding(.horizontal, 16)
            statBlock("EFFORT", "\(engine.workEffortsDone)/\(engine.plan.workPhaseCount)", phaseColor)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(secondaryStatsLabel)
                    .font(Self.labelFont).tracking(1.7)
                    .foregroundStyle(.white.opacity(0.4))
                Text(secondaryStatsText)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(workoutSurface(tint: .white.opacity(0.055)))
    }

    private func statBlock(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Self.labelFont).tracking(1.7)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(numerals(26))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var secondaryStatsLabel: String {
        if engine.plan.equipment == .bike { return "KCAL" }
        return settings.value.useMetric ? "KCAL · KM" : "KCAL · MI"
    }

    private var secondaryStatsText: String {
        let estimate = liveEstimate
        let distance = settings.value.useMetric ? estimate.meters / 1000 : estimate.meters / 1609.34
        if engine.plan.equipment == .bike {
            return String(format: "%.0f", estimate.kcal)
        }
        return String(format: "%.0f · %.1f", estimate.kcal, distance)
    }

    /// Calories and distance so far, from the targets actually being run.
    private var liveEstimate: (kcal: Double, meters: Double) {
        var records: [PhaseRecord] = []
        for (index, phase) in engine.plan.phases.enumerated() {
            let seconds: Double
            if index < engine.phaseIndex {
                seconds = engine.actualSeconds[index]
            } else if index == engine.phaseIndex {
                seconds = engine.inOvertime ? engine.phaseElapsed : min(engine.phaseElapsed, phase.seconds)
            } else {
                seconds = 0
            }
            guard seconds > 0 else { continue }
            let target = engine.appliedTargets[index]
            records.append(PhaseRecord(kind: phase.kind.rawValue,
                                       label: phase.label,
                                       plannedSeconds: phase.seconds,
                                       actualSeconds: seconds,
                                       speedMph: target.speedMph,
                                       inclinePercent: target.inclinePercent,
                                       resistance: target.resistance))
        }
        return MetabolicMath.estimate(records: records,
                                      equipment: engine.plan.equipment,
                                      machine: settings.machine(for: engine.plan.equipment),
                                      weightKg: settings.value.weightKg)
    }

    // MARK: Plan spine — replaces the scrolling interval wheel

    private var spine: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let phases = engine.plan.phases
                let usable = max(0, geo.size.width - gap * CGFloat(max(0, phases.count - 1)))
                let total = max(1, engine.plan.totalSeconds)
                HStack(spacing: gap) {
                    ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                        let isCurrent = index == engine.phaseIndex
                        Capsule()
                            .fill(segmentColor(index: index, phase: phase))
                            .frame(width: max(4, usable * CGFloat(phase.seconds / total)),
                                   height: isCurrent ? 14 : 7)
                            .shadow(color: isCurrent ? phaseColor.opacity(0.9) : .clear, radius: 8)
                    }
                }
                .frame(height: 14, alignment: .center)
            }
            .frame(height: 14)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(engine.isWarning ? Theme.warning.opacity(0.10) : Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(engine.isWarning ? Theme.warning.opacity(0.30) : Color.white.opacity(0.06),
                                lineWidth: 1)))
            .contentShape(Rectangle())
            .onTapGesture { editorOverride = !editorOpen }

            HStack {
                Text(spineCaption)
                    .font(Self.labelFont).tracking(1.7)
                    .foregroundStyle(engine.isWarning ? Theme.warning : .white.opacity(0.3))
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    private func segmentColor(index: Int, phase: IntervalPhase) -> Color {
        if index == engine.phaseIndex { return phaseColor }
        if index < engine.phaseIndex { return Theme.color(for: phase.kind).opacity(0.55) }
        return .white.opacity(0.13)
    }

    private var spineCaption: String {
        if engine.inOvertime { return "COMPLETE" }
        if engine.isWarning, let next = engine.nextPhase { return "\(next.kind.title.uppercased()) NEXT" }
        return "\(engine.plan.name.uppercased()) · \(engine.plan.minutes) MIN"
    }

    // MARK: Effort editor (auto-opens during recoveries)

    private var effortEditor: some View {
        VStack(spacing: 0) {
            ForEach(pastWorkIndices, id: \.self) { index in
                Button {
                    adjustingPhase = AdjustTargetRequest(index: index)
                } label: {
                    HStack(spacing: 10) {
                        Text(engine.plan.phases[index].label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 8)
                        Text(primaryText(engine.appliedTargets[index]))
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                if index != pastWorkIndices.last {
                    Divider().overlay(Color.white.opacity(0.07))
                }
            }
        }
        .background(workoutSurface(tint: .white.opacity(0.07), radius: 18))
    }

    // MARK: Ring — thin outer arc = whole session, thick inner = this phase

    private var ring: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [phaseColor.opacity(0.20), .clear],
                                     center: .center, startRadius: 0, endRadius: 125))
                .padding(26)

            Circle().stroke(Color.white.opacity(0.07), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: sessionProgress)
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle().stroke(Color.white.opacity(0.10), lineWidth: 16).padding(14.5)
            Circle()
                .trim(from: 0, to: engine.phaseProgress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(14.5)
                .animation(.linear(duration: 0.1), value: engine.phaseProgress)

            // The inner padding plus a scale factor keep the numerals fully
            // inside the ring — an un-scalable 84/104pt string used to spill
            // over the arc on compressed layouts.
            VStack(spacing: 5) {
                Text(ringTitle)
                    .font(.system(size: 10.5, weight: engine.isWarning ? .bold : .semibold))
                    .tracking(3.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(phaseColor)
                Text(ringValue)
                    .font(numerals(engine.isWarning ? 104 : 84, .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .foregroundStyle(.white)
                if let cue = ringSubtitle {
                    Text(cue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: 250)
        .aspectRatio(1, contentMode: .fit)
    }

    private var sessionProgress: Double {
        min(1, engine.totalElapsed / max(1, engine.plan.totalSeconds))
    }

    private var ringTitle: String {
        if engine.inOvertime { return "COMPLETE" }
        if engine.isWarning { return "GET READY" }
        return engine.currentPhase.kind.title.uppercased()
    }

    private var ringValue: String {
        if engine.inOvertime { return clockString(engine.overtimeSeconds) }
        if engine.isWarning { return "\(max(1, Int(engine.phaseRemaining.rounded(.up))))" }
        return countdownString(engine.phaseRemaining)
    }

    private var ringSubtitle: String? {
        if engine.state == .paused { return "Paused" }
        if engine.inOvertime || engine.isWarning { return nil }
        return engine.currentPhase.cue
    }

    // MARK: Target card

    private var targetCard: some View {
        Group {
            if engine.isWarning, let next = engine.nextTarget, let nextPhase = engine.nextPhase {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(primaryText(engine.currentTarget))
                            .font(numerals(28, .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                            .strikethrough(true, color: .white.opacity(0.4))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(primaryText(next))
                            .font(numerals(56, .heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Text("\(nextPhase.kind.title.uppercased()) · \(clockString(nextPhase.seconds))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.color(for: nextPhase.kind))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
                .background(workoutSurface(tint: Theme.warning.opacity(0.14),
                                           stroke: Theme.warning.opacity(0.42)))
            } else {
                HStack(spacing: 14) {
                    if adjustable {
                        stepper("minus") { engine.adjustCurrentTarget(up: false) }
                    }
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(primaryText(engine.currentTarget))
                                .font(numerals(44))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            if let secondary = secondaryText(engine.currentTarget) {
                                Text(secondary)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        if engine.currentTargetAdjusted {
                            Text("plan \(primaryText(engine.currentPhase.target))")
                                .font(Self.labelFont).tracking(1.7)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if adjustable {
                        stepper("plus") { engine.adjustCurrentTarget(up: true) }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(workoutSurface(tint: phaseColor.opacity(0.08),
                                           stroke: phaseColor.opacity(0.22)))
            }
        }
    }

    private func stepper(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .light))
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var adjustable: Bool {
        engine.plan.equipment == .bike
            ? engine.currentTarget.resistance != nil
            : engine.currentTarget.speedMph != nil
    }

    private func primaryText(_ target: PhaseTarget) -> String {
        if engine.plan.equipment == .bike {
            if let resistance = target.resistance { return "\(resistance)" }
        } else if let speed = target.speedMph {
            return String(format: "%.1f", settings.value.useMetric ? speed * 1.60934 : speed)
        }
        return target.effortWords
    }

    private func secondaryText(_ target: PhaseTarget) -> String? {
        switch engine.plan.equipment {
        case .bike:
            if let cadence = target.cadenceRPM { return "resist · \(cadence) rpm" }
            return "resistance"
        case .outdoor:
            return (settings.value.useMetric ? "km/h · " : "mph · ") + target.effortWords
        case .treadmill:
            let unit = settings.value.useMetric ? "km/h" : "mph"
            if let incline = target.inclinePercent, incline > 0.5 {
                return String(format: "%@ · %.0f%%", unit, incline)
            }
            return unit
        }
    }

    // MARK: Heart-rate panel — its own view so the chart doesn't rebuild
    // on every 0.1s timer tick, only when heart-rate state actually changes.

    private var hrPanel: some View {
        WorkoutHRPanel(engine: engine)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 34) {
            Button {
                showEndConfirm = true
            } label: {
                Image(systemName: engine.inOvertime ? "checkmark" : "xmark")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 56, height: 56)
                    .background(engine.inOvertime ? Theme.recover.opacity(0.35) : .white.opacity(0.06),
                                in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.09), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Button {
                engine.state == .paused ? engine.resume() : engine.pause()
            } label: {
                Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 74, height: 74)
                    .background(.white.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                    .foregroundStyle(.white)
            }
            Button {
                engine.skip()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.06), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.09), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.85))
            }
            // The engine ignores skips while paused — dim the button too, so
            // it doesn't read as a live control that does nothing.
            .opacity(engine.inOvertime || engine.state == .paused ? 0.3 : 1)
            .disabled(engine.inOvertime || engine.state == .paused)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Heart-rate panel

/// Isolated from the 10 Hz timer-driven parent so the Swift Charts graph is
/// only rebuilt when a heart-rate value arrives (~1/s) — a 60-minute session
/// accumulates ~1800 samples, and rebuilding thousands of marks ten times a
/// second burned main-thread CPU exactly when the screen stays on longest.
private struct WorkoutHRPanel: View {
    let engine: WorkoutEngine
    @Environment(BluetoothHeartRateManager.self) private var ble

    private static let labelFont = Font.system(size: 9.5, weight: .semibold)

    var body: some View {
        // The periodic timeline re-evaluates staleness every few seconds so
        // "– –" replaces the last reading when a source goes quiet.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            VStack(alignment: .leading, spacing: 11) {
                header
                if !engine.coachMessage.isEmpty {
                    Text(engine.coachMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                chart
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 10)
            .background(workoutSurface(tint: .white.opacity(0.055)))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color(hex: 0xFF3B30))
                .frame(width: 8, height: 8)
                .shadow(color: Color(hex: 0xFF3B30).opacity(0.9), radius: 5)
            if let hr = liveHR {
                Text("\(Int(hr))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("BPM")
                    .font(Self.labelFont).tracking(1.7)
                    .foregroundStyle(.white.opacity(0.4))
                if let maxHR = engine.maxHR {
                    Text(HeartRateZone.zone(forPercent: hr / maxHR * 100).label.uppercased())
                        .font(Self.labelFont).tracking(1.7)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(Color(hex: 0xFFC470))
                        .fixedSize()
                }
            } else {
                Text("– –")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                Text(hrHint)
                    .font(Self.labelFont).tracking(1.4)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if let summary = hrSummary {
                Text(summary)
                    .font(Self.labelFont).tracking(1.7)
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if engine.hrHistory.count >= 2 {
            let baseline = graphYDomain.lowerBound
            Chart {
                ForEach(displaySamples, id: \.date) { sample in
                    // Anchoring the area's base at the visible domain floor
                    // (instead of the implicit y = 0) keeps the red gradient
                    // from spilling below the bottom edge of the plot.
                    AreaMark(
                        x: .value("Minutes", sample.date.timeIntervalSince(engine.startDate) / 60),
                        yStart: .value("Base", baseline),
                        yEnd: .value("BPM", sample.bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(
                            colors: [Color(hex: 0xFF3B30).opacity(0.40), Color(hex: 0xFF3B30).opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Minutes", sample.date.timeIntervalSince(engine.startDate) / 60),
                        y: .value("BPM", sample.bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color(hex: 0xFF3B30))
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if let last = engine.hrHistory.last {
                    PointMark(x: .value("Minutes", last.date.timeIntervalSince(engine.startDate) / 60),
                              y: .value("BPM", last.bpm))
                        .symbolSize(70)
                        .foregroundStyle(Color(hex: 0xFF3B30))
                }
            }
            .chartXScale(domain: 0...graphMaxMinutes)
            .chartYScale(domain: graphYDomain)
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: yAxisValues) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.055))
                    AxisValueLabel {
                        if let bpm = value.as(Double.self) {
                            Text("\(Int(bpm))")
                                .font(Self.labelFont)
                                .foregroundStyle(.white.opacity(0.32))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: xAxisValues) { value in
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text("\(Int(minutes))")
                                .font(Self.labelFont).tracking(1.1)
                                .foregroundStyle(.white.opacity(0.28))
                        }
                    }
                }
            }
            .frame(height: 116)
        } else {
            Text("Heart-rate curve draws here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, minHeight: 116)
        }
    }

    private var liveHR: Double? {
        guard let hr = engine.latestHR, let date = engine.latestHRDate,
              Date().timeIntervalSince(date) < 30 else { return nil }
        return hr
    }

    /// Long sessions are thinned to a few hundred points before charting —
    /// visually identical, far cheaper to lay out.
    private var displaySamples: [HRSample] {
        let samples = engine.hrHistory
        let cap = 600
        guard samples.count > cap else { return samples }
        let step = Double(samples.count) / Double(cap)
        var out: [HRSample] = []
        out.reserveCapacity(cap + 1)
        var i = 0.0
        while Int(i) < samples.count {
            out.append(samples[Int(i)])
            i += step
        }
        if let last = samples.last, out.last?.date != last.date {
            out.append(last)
        }
        return out
    }

    private var hrSummary: String? {
        let values = engine.hrHistory.map(\.bpm)
        guard let hi = values.max(), !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "AVG %.0f · MAX %.0f", avg, hi)
    }

    private var graphMaxMinutes: Double {
        let lastSample = engine.hrHistory.last?.date.timeIntervalSince(engine.startDate) ?? 0
        return max(engine.plan.totalSeconds, lastSample + 15) / 60
    }

    private var graphYDomain: ClosedRange<Double> {
        let values = engine.hrHistory.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 110...185 }
        return max(40, lo - 12)...(hi + 15)
    }

    /// Four round bpm gridlines inside whatever range is in play.
    private var yAxisValues: [Double] {
        let lower = graphYDomain.lowerBound, upper = graphYDomain.upperBound
        let step = max(10, ((upper - lower) / 4 / 10).rounded() * 10)
        let start = (lower / step).rounded(.up) * step
        return (0..<4).map { start + Double($0) * step }.filter { $0 < upper }
    }

    private var xAxisValues: [Double] {
        let total = graphMaxMinutes
        let step = total > 40 ? 15.0 : (total > 20 ? 10.0 : 5.0)
        return Array(stride(from: 0, through: total, by: step))
    }

    private var hrHint: String {
        switch ble.status {
        case .connected(let name): return "LIVE FROM \(name.uppercased())"
        case .connecting(let name): return "CONNECTING TO \(name.uppercased())…"
        case .bluetoothOff: return "BLUETOOTH IS OFF"
        default: return "NO LIVE HR"
        }
    }
}

// MARK: - Shared surface style — specular top edge + soft drop shadow

private func workoutSurface(tint: Color,
                            stroke: Color = .white.opacity(0.08),
                            radius: CGFloat = 20) -> some View {
    RoundedRectangle(cornerRadius: radius)
        .fill(tint)
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: 1))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                .mask(LinearGradient(colors: [.white, .clear],
                                     startPoint: .top, endPoint: .center)))
        .shadow(color: .black.opacity(0.35), radius: 13, y: 10)
}

/// "That sprint was actually faster/slower": corrects a completed effort and
/// recalibrates the rest of the workout.
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
            Text("Applies to the rest of today's efforts and next session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
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
