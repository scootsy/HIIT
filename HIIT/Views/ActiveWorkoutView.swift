import SwiftUI

/// Owns the engine for one session, feeds it live heart-rate samples, and
/// swaps to the summary screen when the workout ends.
struct ActiveWorkoutContainerView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HealthKitManager.self) private var health
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
            health.startHeartRateUpdates()
        }
        .onDisappear {
            health.stopHeartRateUpdates()
        }
        .onChange(of: health.liveHeartRate) { _, newValue in
            if let bpm = newValue {
                engine.recordHeartRate(bpm, at: health.liveHeartRateDate ?? Date())
            }
        }
    }
}

struct ActiveWorkoutView: View {
    let engine: WorkoutEngine
    @Environment(SettingsStore.self) private var settings
    @State private var showEndConfirm = false

    private var phaseColor: Color {
        engine.isWarning ? Theme.steady : Theme.color(for: engine.currentPhase.kind)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [phaseColor.opacity(0.42), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: phaseColor)

            VStack(spacing: 14) {
                topBar
                Spacer(minLength: 4)
                ring
                targetRow
                Spacer(minLength: 4)
                nextUp
                hrCard
                controls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("End this workout?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("End workout", role: .destructive) { engine.endWorkout() }
            Button("Keep going", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(clockString(engine.totalElapsed))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Spacer()
            Text(engine.currentPhase.label)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("REMAINING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(clockString(engine.totalRemaining))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 16)
            Circle()
                .trim(from: 0, to: engine.phaseProgress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: engine.phaseProgress)
            VStack(spacing: 4) {
                Text(engine.isWarning ? "GET READY" : engine.currentPhase.kind.title.uppercased())
                    .font(.subheadline.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(phaseColor)
                Text(countdownString(engine.phaseRemaining))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(engine.state == .paused ? "Paused" : engine.currentPhase.cue)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: 300)
        .aspectRatio(1, contentMode: .fit)
    }

    /// The live target, with ± to say "I'm actually going faster/slower than
    /// that" — the change sticks for every remaining phase of the same kind
    /// and flows into distance, calories, and next-session targets.
    private var targetRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 18) {
                if adjustable {
                    Button {
                        engine.adjustCurrentTarget(up: false)
                    } label: {
                        Image(systemName: "minus")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.1), in: Circle())
                            .foregroundStyle(.white)
                    }
                }
                Text(targetLine(for: engine.currentTarget, equipment: engine.plan.equipment, settings: settings))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if adjustable {
                    Button {
                        engine.adjustCurrentTarget(up: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.1), in: Circle())
                            .foregroundStyle(.white)
                    }
                }
            }
            if engine.currentTargetAdjusted {
                Text("adjusted — plan was \(targetLine(for: engine.currentPhase.target, equipment: engine.plan.equipment, settings: settings))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var adjustable: Bool {
        if engine.plan.equipment == .bike {
            return engine.currentTarget.resistance != nil
        }
        return engine.currentTarget.speedMph != nil
    }

    private var nextUp: some View {
        Group {
            if let next = engine.nextPhase {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(engine.isWarning ? Theme.steady : .white.opacity(0.6))
                        .symbolEffect(.pulse, isActive: engine.isWarning)
                    Text("Next: \(next.kind.title.lowercased()) · \(targetLine(for: engine.nextTarget ?? next.target, equipment: engine.plan.equipment, settings: settings))")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    Text("in \(Int(engine.phaseRemaining.rounded(.up)))s")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(engine.isWarning ? Theme.steady : .white.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(engine.isWarning ? 0.14 : 0.07), in: Capsule())
                .overlay(Capsule().stroke(engine.isWarning ? Theme.steady : .clear, lineWidth: 1.5))
            } else {
                EmptyView()
            }
        }
    }

    private var hrCard: some View {
        HStack(spacing: 10) {
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
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Text("– –")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Text(engine.coachMessage.isEmpty ? "Live HR needs a Watch workout or HR strap" : engine.coachMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                showEndConfirm = true
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.1), in: Circle())
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
                    .frame(width: 76, height: 76)
                    .background(.white.opacity(0.16), in: Circle())
                    .foregroundStyle(.white)
            }
            Button {
                engine.skip()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.1), in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 6)
    }
}
