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
    @State private var liveActivity = WorkoutActivityController()

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
            engine.spokenCuesOn = settings.value.spokenCuesOn
            engine.maxHR = settings.maxHR
            engine.machine = settings.machine(for: engine.plan.equipment)
            engine.speechLine = { [weak settings] event in
                guard let settings else { return nil }
                return SpeechScript.line(for: event, useMetric: settings.value.useMetric)
            }
            // Direct sample tap: SwiftUI onChange can go quiet in the
            // background, but the BLE callback keeps firing (bluetooth-central
            // background mode) — feed the engine straight from it.
            ble.onSample = { [weak engine] bpm, date in
                engine?.recordHeartRate(bpm, at: date, fromBLE: true)
            }
            // Same story for the lock screen: the engine calls this on phase
            // transitions and coach-suggestion changes so the Live Activity
            // stays current while the app is backgrounded.
            engine.onLiveStateChange = { [weak engine, weak liveActivity, weak settings] in
                guard let engine, let settings else { return }
                liveActivity?.update(engine: engine, settings: settings)
            }
            engine.start()
            ble.workoutActive = true
            if let idString = settings.value.hrMonitorID, let uuid = UUID(uuidString: idString) {
                ble.connectToSaved(id: uuid, name: settings.value.hrMonitorName ?? "your monitor")
            }
            health.startHeartRateUpdates()
            // Lock-screen intents run in this process while the app is
            // backgrounded, so the handlers update the Live Activity
            // directly — SwiftUI onChange may not fire back there.
            WorkoutIntentBridge.adjust = { [weak engine, weak liveActivity, weak settings] up in
                guard let engine, let settings else { return }
                engine.adjustCurrentTarget(up: up)
                liveActivity?.update(engine: engine, settings: settings)
            }
            WorkoutIntentBridge.togglePause = { [weak engine, weak liveActivity, weak settings] in
                guard let engine, let settings else { return }
                engine.state == .paused ? engine.resume() : engine.pause()
                liveActivity?.update(engine: engine, settings: settings)
            }
            WorkoutIntentBridge.acceptSuggestion = { [weak engine, weak liveActivity, weak settings] in
                guard let engine, let settings else { return }
                engine.acceptSuggestion()
                liveActivity?.update(engine: engine, settings: settings)
            }
            WorkoutIntentBridge.dismissSuggestion = { [weak engine, weak liveActivity, weak settings] in
                guard let engine, let settings else { return }
                engine.dismissSuggestion()
                liveActivity?.update(engine: engine, settings: settings)
            }
            liveActivity.start(engine: engine, settings: settings)
        }
        .onDisappear {
            ble.workoutActive = false
            ble.onSample = nil
            ble.disconnect()
            health.stopHeartRateUpdates()
            engine.onLiveStateChange = nil
            WorkoutIntentBridge.adjust = nil
            WorkoutIntentBridge.togglePause = nil
            WorkoutIntentBridge.acceptSuggestion = nil
            WorkoutIntentBridge.dismissSuggestion = nil
            liveActivity.end()
            SpeechCoach.shared.stop()
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
            liveActivity.update(engine: engine, settings: settings)
        }
        .onChange(of: engine.state) { _, newState in
            if newState == .finished {
                WorkoutCheckpoint.save(engine.makeCheckpoint())
                liveActivity.end()
            } else {
                // Pause/resume: swap the live countdown for a frozen one.
                liveActivity.update(engine: engine, settings: settings)
            }
        }
        // In-app steppers and the past-effort editor retarget later phases —
        // keep the lock screen's numbers in step.
        .onChange(of: engine.appliedTargets) { _, _ in
            liveActivity.update(engine: engine, settings: settings)
        }
        .onChange(of: engine.inOvertime) { _, _ in
            liveActivity.update(engine: engine, settings: settings)
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

/// The live screen lays itself out for the space it's given, never for a
/// named device:
///
/// - **One column** — a phone held upright, iPhone Duo's cover display, its
///   inner display in portrait, half of it in Split View. Stats → plan spine
///   (tap it to open the effort editor) → timer ring → target → heart rate →
///   controls. The ring and the heart-rate panel flex so the column exactly
///   fills the screen: a short display gets a smaller ring and drops the
///   chart, a tall one grows both. Nothing scrolls unless it truly can't fit
///   (the effort editor open on a small screen).
/// - **Two panes side by side** — any landscape canvas, and a Duo folded like
///   a book: the ring and the target on one side, stats, heart rate and
///   controls on the other, with the crease in the gap between them.
/// - **Two panes stacked** — a Duo folded like a laptop: the ring and target
///   on the upright half, everything you touch on the half lying flat.
///
/// The amber early warning tints only the ring, the spine's current segment
/// and the target card — never the background.
struct ActiveWorkoutView: View {
    let engine: WorkoutEngine
    @Environment(SettingsStore.self) private var settings
    @State private var showEndConfirm = false
    @State private var adjustingPhase: AdjustTargetRequest? = nil
    /// Opens only on a spine tap; auto-closes when the phase changes.
    @State private var editorOpen = false

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
                arranged(size: geo.size, fold: geo.foldDivision)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: editorOpen)
        .onChange(of: engine.phaseIndex) { _, _ in
            editorOpen = false
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

    // MARK: Arrangement

    enum Arrangement: Equatable {
        case column
        /// Leading pane width, then the gap (the crease, when folded).
        case sideBySide(leading: CGFloat, gap: CGFloat)
        /// Top pane height, then the gap (the crease).
        case stacked(top: CGFloat, gap: CGFloat)
    }

    static func arrangement(for size: CGSize, fold: FoldDivision?) -> Arrangement {
        if let fold {
            // Keep each pane wholly on one side of the crease.
            if fold.isVertical {
                return .sideBySide(leading: fold.frame.minX, gap: fold.frame.width)
            }
            return .stacked(top: fold.frame.minY, gap: fold.frame.height)
        }
        // Clearly wider than tall, with room for two real panes: landscape.
        if size.width >= 560, size.width >= size.height * 1.15 {
            let gap: CGFloat = 16
            return .sideBySide(leading: ((size.width - gap) / 2).rounded(.down), gap: gap)
        }
        return .column
    }

    @ViewBuilder
    private func arranged(size: CGSize, fold: FoldDivision?) -> some View {
        switch Self.arrangement(for: size, fold: fold) {
        case .column:
            pane(width: size.width, height: size.height, maxContentWidth: 560) { space in
                columnStack(space)
            }
        case .sideBySide(let leading, let gap):
            HStack(spacing: 0) {
                pane(width: leading, height: size.height) { space in
                    focusStack(space)
                }
                Color.clear.frame(width: gap)
                pane(width: max(0, size.width - leading - gap), height: size.height) { space in
                    dataStack(space)
                }
            }
        case .stacked(let top, let gap):
            VStack(spacing: 0) {
                pane(width: size.width, height: top) { space in
                    focusStack(space)
                }
                Color.clear.frame(height: gap)
                pane(width: size.width, height: max(0, size.height - top - gap)) { space in
                    dataStack(space)
                }
            }
        }
    }

    /// One region of the screen. Its content is told how much room it has
    /// and fills it exactly when it fits; when it can't (a very short pane,
    /// the effort editor open) the region scrolls instead of clipping the
    /// controls away.
    private func pane<Content: View>(width: CGFloat,
                                     height: CGFloat,
                                     maxContentWidth: CGFloat = .infinity,
                                     @ViewBuilder content: (CGSize) -> Content) -> some View {
        let inset: CGFloat = width < 350 ? 14 : 22
        let vertical: CGFloat = height < 430 ? 8 : 14
        let space = CGSize(width: max(0, min(width - inset * 2, maxContentWidth)),
                           height: max(0, height - vertical * 2))
        return ScrollView(showsIndicators: false) {
            content(space)
                .frame(width: space.width)
                .padding(.vertical, vertical)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: height)
    }

    private func rowSpacing(_ space: CGSize) -> CGFloat {
        space.height < 430 ? 10 : 12
    }

    /// Everything in one column.
    private func columnStack(_ space: CGSize) -> some View {
        FlexVStack(spacing: rowSpacing(space)) {
            statsCard
            spine
            if editorOpen, !pastWorkIndices.isEmpty { effortEditor }
            ring
                .flexHeight(min: 150, ideal: 200, max: min(360, space.width), weight: 1)
            targetCard
            if let hint = upNextHint { hintLine(hint) }
            WorkoutHRPanel(engine: engine)
                .flexHeight(min: hrPanelMinimum, ideal: 150, max: 330, weight: 0.55, yields: true)
            controls
        }
    }

    /// The glanceable pane: the timer and what to hold right now.
    @ViewBuilder
    private func focusStack(_ space: CGSize) -> some View {
        if space.width > space.height * 1.45 {
            // A wide, short strip (the upright half of a laptop-style fold):
            // ring beside the target instead of above it.
            let diameter = max(120, min(space.height, 320, space.width * 0.42))
            HStack(spacing: 24) {
                ring.frame(width: diameter, height: diameter)
                VStack(spacing: 10) {
                    targetCard
                    if let hint = upNextHint { hintLine(hint) }
                }
                .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity)
        } else {
            FlexVStack(spacing: rowSpacing(space)) {
                ring
                    .flexHeight(min: 130, ideal: 200, max: min(380, space.width), weight: 1)
                targetCard
                if let hint = upNextHint { hintLine(hint) }
            }
        }
    }

    /// The pane you read at a glance less often and touch more: stats, plan,
    /// heart rate, controls.
    @ViewBuilder
    private func dataStack(_ space: CGSize) -> some View {
        if space.width > space.height * 1.9, space.width >= 620 {
            // A wide, short strip (the flat half of a laptop-style fold):
            // controls beside the data instead of beneath it.
            HStack(spacing: 28) {
                FlexVStack(spacing: rowSpacing(space)) {
                    statsCard
                    spine
                    if editorOpen, !pastWorkIndices.isEmpty { effortEditor }
                    WorkoutHRPanel(engine: engine)
                        .flexHeight(min: hrPanelMinimum, ideal: 150, max: 420, weight: 1)
                }
                .frame(minHeight: space.height)
                controls
            }
        } else {
            FlexVStack(spacing: rowSpacing(space)) {
                statsCard
                spine
                if editorOpen, !pastWorkIndices.isEmpty { effortEditor }
                WorkoutHRPanel(engine: engine)
                    .flexHeight(min: hrPanelMinimum, ideal: 150, max: 420, weight: 1)
                controls
            }
        }
    }

    /// The heart-rate panel can shrink to its header, but never so far that
    /// a live suggestion's Apply button would be cut off.
    private var hrPanelMinimum: CGFloat {
        if engine.liveSuggestion != nil { return 140 }
        return engine.coachMessage.isEmpty ? 58 : 86
    }

    // MARK: Stats card

    private var statsCard: some View {
        // A narrow pane (half a folded Duo, Split View) drops the kcal ·
        // distance readout before it squeezes the two numbers that matter.
        ViewThatFits(in: .horizontal) {
            statsRow(showSecondary: true)
            statsRow(showSecondary: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(workoutSurface(tint: .white.opacity(0.055)))
    }

    private func statsRow(showSecondary: Bool) -> some View {
        HStack(spacing: 0) {
            statBlock("REMAINING",
                      engine.inOvertime ? "+\(clockString(engine.overtimeSeconds))" : clockString(engine.totalRemaining),
                      .white)
            Divider().frame(height: 34).overlay(Color.white.opacity(0.10)).padding(.horizontal, 16)
            if engine.plan.effectiveMode == .endurance {
                statBlock("TARGET", enduranceTargetText, phaseColor)
            } else {
                statBlock("EFFORT", "\(engine.workEffortsDone)/\(engine.plan.workPhaseCount)", phaseColor)
            }
            Spacer(minLength: 8)
            if showSecondary {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(secondaryStatsLabel)
                        .font(Self.labelFont).tracking(1.7)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                    Text(secondaryStatsText)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var enduranceTargetText: String {
        guard let low = engine.currentTarget.hrPercentLow,
              let high = engine.currentTarget.hrPercentHigh else { return "EASY" }
        return "\(Int(low))–\(Int(high))%"
    }

    private func statBlock(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Self.labelFont).tracking(1.7)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
            Text(value)
                .font(numerals(26))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
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
        return String(format: "%.0f · %.2f", estimate.kcal, distance)
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
            .onTapGesture { editorOpen.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workout plan, phase \(min(engine.phaseIndex + 1, engine.plan.phases.count)) of \(engine.plan.phases.count)")
            .accessibilityHint("Opens the list of finished efforts so you can correct one")
            .accessibilityAddTraits(.isButton)

            HStack {
                Text(spineCaption)
                    .font(Self.labelFont).tracking(1.7)
                    .foregroundStyle(engine.isWarning ? Theme.warning : .white.opacity(0.3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

    // MARK: Effort editor (opens on spine tap)

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
                            .lineLimit(1)
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
                .accessibilityHint("Corrects this effort's speed or resistance")
                if index != pastWorkIndices.last {
                    Divider().overlay(Color.white.opacity(0.07))
                }
            }
        }
        .background(workoutSurface(tint: .white.opacity(0.07), radius: 18))
    }

    // MARK: Ring — thin outer arc = whole session, thick inner = this phase

    /// Draws at whatever size it's given: every stroke, inset and numeral is
    /// proportional to the diameter, so a 150-point ring on a short display
    /// is the same picture as a 360-point one on the Duo's inner display.
    private var ring: some View {
        GeometryReader { geo in
            let side = max(0, min(geo.size.width, geo.size.height))
            let scale = side / 250
            // Small labels shrink and grow less than the ring itself.
            let labelScale = max(0.85, min(scale, 1.35))
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [phaseColor.opacity(0.20), .clear],
                                         center: .center, startRadius: 0, endRadius: max(1, side / 2)))
                    .padding(26 * scale)

                Circle().stroke(Color.white.opacity(0.07), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: sessionProgress)
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Circle().stroke(Color.white.opacity(0.10), lineWidth: 16 * scale).padding(14.5 * scale)
                Circle()
                    .trim(from: 0, to: engine.phaseProgress)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 16 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(14.5 * scale)
                    .animation(.linear(duration: 0.1), value: engine.phaseProgress)

                // The inner padding plus a scale factor keep the numerals
                // fully inside the ring at every size.
                VStack(spacing: 5 * scale) {
                    Text(ringTitle)
                        .font(.system(size: 10.5 * labelScale, weight: engine.isWarning ? .bold : .semibold))
                        .tracking(3.4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(phaseColor)
                    Text(ringValue)
                        .font(numerals((engine.isWarning ? 104 : 84) * scale, .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                        .foregroundStyle(.white)
                    if let cue = ringSubtitle {
                        Text(cue)
                            .font(.system(size: 14 * labelScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(40 * scale)
            }
            .frame(width: side, height: side)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
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

    private var ringAccessibilityLabel: String {
        if engine.inOvertime { return "Workout complete" }
        let seconds = Int(engine.phaseRemaining.rounded(.up))
        let remaining = seconds >= 60
            ? "\(seconds / 60) minutes \(seconds % 60) seconds"
            : "\(seconds) seconds"
        let paused = engine.state == .paused ? ", paused" : ""
        return "\(engine.currentPhase.kind.title), \(remaining) remaining\(paused)"
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
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(primaryText(next))
                            .font(numerals(56, .heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    Text("\(nextPhase.kind.title.uppercased()) · \(clockString(nextPhase.seconds))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.color(for: nextPhase.kind))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .padding(.horizontal, 14)
                .background(workoutSurface(tint: Theme.warning.opacity(0.14),
                                           stroke: Theme.warning.opacity(0.42)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Get ready: \(nextPhase.kind.title), \(spokenTarget(next))")
            } else {
                HStack(spacing: 14) {
                    if adjustable {
                        stepper("minus", label: "Decrease target") { engine.adjustCurrentTarget(up: false) }
                    }
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(primaryText(engine.currentTarget))
                                .font(numerals(44))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            if let secondary = secondaryText(engine.currentTarget) {
                                Text(secondary)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                        if engine.currentTargetAdjusted {
                            Text("plan \(primaryText(engine.currentPhase.target))")
                                .font(Self.labelFont).tracking(1.7)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Target: \(spokenTarget(engine.currentTarget))")
                    if adjustable {
                        stepper("plus", label: "Increase target") { engine.adjustCurrentTarget(up: true) }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(workoutSurface(tint: phaseColor.opacity(0.08),
                                           stroke: phaseColor.opacity(0.22)))
            }
        }
    }

    private func stepper(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .light))
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.1), lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func hintLine(_ hint: String) -> some View {
        Text(hint)
            .font(Self.labelFont).tracking(1.7)
            .foregroundStyle(.white.opacity(0.38))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    /// One quiet line under the target card: what's coming and at what
    /// setting. The amber warning gives 10s to adjust the machine, but
    /// knowing the numbers ahead of time is what makes the change easy —
    /// this preps the user well before the countdown starts.
    private var upNextHint: String? {
        guard !engine.inOvertime, !engine.isWarning,
              let next = engine.nextPhase, let target = engine.nextTarget else { return nil }
        var parts = ["UP NEXT", "\(next.kind.title.uppercased()) \(clockString(next.seconds))"]
        switch engine.plan.equipment {
        case .bike:
            if let resistance = target.resistance {
                var value = "R\(resistance)"
                if let cadence = target.cadenceRPM { value += " · \(cadence) RPM" }
                parts.append(value)
            }
        case .treadmill, .outdoor:
            if let speed = target.speedMph {
                var value = String(format: "%.1f", settings.value.useMetric ? speed * 1.60934 : speed)
                value += settings.value.useMetric ? " KM/H" : " MPH"
                if let incline = target.inclinePercent, incline > 0.5 {
                    value += String(format: " · %.0f%%", incline)
                }
                parts.append(value)
            }
        }
        return parts.joined(separator: " · ")
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

    /// The target as a sentence, for VoiceOver.
    private func spokenTarget(_ target: PhaseTarget) -> String {
        targetLine(for: target, equipment: engine.plan.equipment, settings: settings)
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
            .accessibilityLabel(engine.inOvertime ? "Finish workout" : "End workout")
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
            .accessibilityLabel(engine.state == .paused ? "Resume" : "Pause")
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
            .accessibilityLabel("Skip to next phase")
        }
        .fixedSize()
        .padding(.bottom, 4)
    }
}

// MARK: - Heart-rate panel

/// Isolated from the 10 Hz timer-driven parent so the Swift Charts graph is
/// only rebuilt when a heart-rate value arrives (~1/s) — a 60-minute session
/// accumulates ~1800 samples, and rebuilding thousands of marks ten times a
/// second burned main-thread CPU exactly when the screen stays on longest.
///
/// The panel draws at whatever height the layout gives it: the header (and
/// any coach line or suggestion) always shows, and the chart takes the rest
/// — or steps aside entirely when there isn't room for a readable one.
private struct WorkoutHRPanel: View {
    let engine: WorkoutEngine
    @Environment(BluetoothHeartRateManager.self) private var ble
    @Environment(SettingsStore.self) private var settings

    private static let labelFont = Font.system(size: 9.5, weight: .semibold)
    /// Below this a chart is a smudge, not a curve.
    private static let minimumChartHeight: CGFloat = 52

    var body: some View {
        // The periodic timeline re-evaluates staleness every few seconds so
        // "– –" replaces the last reading when a source goes quiet.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                header
                if let suggestion = engine.liveSuggestion {
                    suggestionChip(suggestion)
                        .padding(.top, 11)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if !engine.coachMessage.isEmpty {
                    Text(engine.coachMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.top, 11)
                }
                // Whatever height is left belongs to the chart.
                GeometryReader { space in
                    if space.size.height >= Self.minimumChartHeight + 11 {
                        chart(compact: space.size.height < 96)
                            .padding(.top, 11)
                            .frame(width: space.size.width, height: space.size.height)
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.25), value: engine.liveSuggestion?.id)
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(workoutSurface(tint: .white.opacity(0.055)))
        }
    }

    /// The live coach's one-tap offer: accept applies it through the same
    /// override path as the manual steppers; the x just clears it.
    private func suggestionChip(_ suggestion: LiveCoach.Suggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.steps < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(suggestion.steps < 0 ? Theme.recover : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(suggestionValueText(suggestion))
                    .font(Self.labelFont).tracking(1.4)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button { engine.acceptSuggestion() } label: {
                Text("APPLY")
                    .font(Self.labelFont).tracking(1.7)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apply suggestion")
            Button { engine.dismissSuggestion() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.08), in: Circle())
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke((suggestion.steps < 0 ? Theme.recover : Theme.accent).opacity(0.35),
                                lineWidth: 1)))
    }

    private func suggestionValueText(_ suggestion: LiveCoach.Suggestion) -> String {
        LiveCoach.valueText(for: suggestion, engine: engine, useMetric: settings.value.useMetric)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func chart(compact: Bool) -> some View {
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
                AxisMarks(position: .leading, values: yAxisValues(count: compact ? 2 : 4)) { value in
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
            .accessibilityLabel("Heart-rate chart")
        } else {
            Text("Heart-rate curve draws here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// A few round bpm gridlines inside whatever range is in play — fewer
    /// when the chart is short, so the labels never collide.
    private func yAxisValues(count: Int) -> [Double] {
        let lower = graphYDomain.lowerBound, upper = graphYDomain.upperBound
        let step = max(10, ((upper - lower) / Double(count) / 10).rounded() * 10)
        let start = (lower / step).rounded(.up) * step
        return (0..<count).map { start + Double($0) * step }.filter { $0 < upper }
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
