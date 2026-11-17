#if DEBUG
import SwiftUI
import SwiftData
import UIKit

/// Debug builds only — none of this is compiled into a release.
///
/// Opens the app straight onto one screen, filled with sample data, so a
/// layout can be checked (and photographed by CI) without tapping through a
/// workout. Driven by launch arguments:
///
///     xcrun simctl launch booted com.scootsy.HIIT -demoScreen workout -demoState warning
///
/// - `-demoScreen`  home · history · settings · detail · setup · workout ·
///   summary · welcome
/// - `-demoState`   (workout) work · warning · recover · suggestion · paused ·
///   overtime · endurance
/// - `-demoEquipment`  treadmill · bike · outdoor
/// - `-demoCanvas WxH`  draw the screen in a canvas of that many points,
///   scaled to fit the window — any pose of any device on one simulator
///   (466x678 for a closed iPhone Duo, 951x669 for an open one on its side,
///   310x890 for one half of a book fold…). Custom layouts respond exactly;
///   system bars and sheets still follow the real window.
/// - `-demoOrientation landscape`  ask the scene to rotate
/// - `-demoInfo 1`  overlay the window's safe area, size classes, and (iOS
///   27.1+) the fold and camera regions the system reports
/// - `-demoSnapshot NAME`  two seconds after the screen appears, save a
///   picture of it as Documents/demo-snapshots/NAME.jpg (plus NAME.txt with
///   the window size and whatever the info overlay shows) — how
///   scripts/screenshots.sh collects its pictures
///
/// Nothing here reads or writes the real settings, workout history, Health
/// or Bluetooth.
struct DemoMode {
    var screen: String
    var state: String
    var equipment: Equipment
    var canvas: CGSize?
    var landscape: Bool?
    var showInfo: Bool
    var snapshotName: String?

    static let current: DemoMode? = {
        let defaults = UserDefaults.standard
        guard let screen = defaults.string(forKey: "demoScreen"), !screen.isEmpty else { return nil }

        var canvas: CGSize? = nil
        if let text = defaults.string(forKey: "demoCanvas") {
            let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] >= 100, parts[1] >= 100 {
                canvas = CGSize(width: parts[0], height: parts[1])
            }
        }
        var landscape: Bool? = nil
        if let orientation = defaults.string(forKey: "demoOrientation") {
            landscape = orientation == "landscape"
        }
        // The real root view shows the welcome sheet until this is set.
        defaults.set(screen != "welcome", forKey: "hiit.hasOnboarded")

        return DemoMode(screen: screen,
                        state: defaults.string(forKey: "demoState") ?? "work",
                        equipment: Equipment(rawValue: defaults.string(forKey: "demoEquipment") ?? "") ?? .treadmill,
                        canvas: canvas,
                        landscape: landscape,
                        showInfo: defaults.bool(forKey: "demoInfo"),
                        snapshotName: defaults.string(forKey: "demoSnapshot"))
    }()
}

struct DemoRootView: View {
    let demo: DemoMode

    @State private var settings: SettingsStore
    @State private var health = HealthKitManager()
    @State private var ble = BluetoothHeartRateManager()
    @State private var engine: WorkoutEngine
    private let container: ModelContainer
    private let sampleSession: WorkoutSession?

    init(demo: DemoMode) {
        self.demo = demo

        var profile = AppSettings()
        profile.age = 34
        profile.weightKg = 78
        profile.heightCm = 178
        profile.restingHR = 56
        profile.experienceRaw = ExperienceLevel.intermediate.rawValue
        profile.experienceSetOnce = true
        profile.machines[Equipment.treadmill.rawValue] = MachineProfile.defaults(for: .treadmill)
        profile.machines[Equipment.bike.rawValue] = MachineProfile.defaults(for: .bike)
        let store = SettingsStore(ephemeral: profile)
        _settings = State(initialValue: store)

        let schema = Schema(versionedSchema: HIITSchemaV2.self)
        let memory = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        container = memory
        sampleSession = DemoData.seed(into: memory.mainContext, settings: store)
        _engine = State(initialValue: DemoData.engine(for: demo, settings: store))
    }

    var body: some View {
        DemoCanvas(canvas: demo.canvas) {
            screen
        }
        .environment(settings)
        .environment(health)
        .environment(ble)
        .modelContainer(container)
        .tint(Theme.accent)
        .overlay {
            if demo.showInfo {
                DemoInfoOverlay()
            }
        }
        .onAppear(perform: applyOrientation)
        .task {
            guard let name = demo.snapshotName, !name.isEmpty else { return }
            // Long enough for a rotation, a sheet or a chart to settle.
            try? await Task.sleep(for: .seconds(2))
            await DemoSnapshot.save(named: name)
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch demo.screen {
        case "workout":
            ActiveWorkoutView(engine: engine)
        case "summary":
            SummaryView(engine: engine) {}
        case "history":
            RootView(initialTab: .history)
        case "settings":
            RootView(initialTab: .settings)
        case "detail":
            if let sampleSession {
                NavigationStack {
                    SessionDetailView(session: sampleSession)
                }
            }
        case "setup":
            SetupView(onStart: { _ in }, demoEquipment: demo.equipment)
        case "welcome":
            WelcomeView()
        default:
            RootView()
        }
    }

    private func applyOrientation() {
        guard let landscape = demo.landscape else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                windowScene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
            }
        }
    }
}

/// Draws its content at a fixed point size, scaled down to fit the window —
/// with the size classes that canvas would have.
private struct DemoCanvas<Content: View>: View {
    let canvas: CGSize?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let canvas {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / canvas.width, geo.size.height / canvas.height)
                content()
                    .frame(width: canvas.width, height: canvas.height)
                    .environment(\.horizontalSizeClass,
                                 canvas.width >= 600 ? UserInterfaceSizeClass.regular : .compact)
                    .environment(\.verticalSizeClass,
                                 canvas.height >= 480 ? UserInterfaceSizeClass.regular : .compact)
                    .background(Color.black)
                    .clipped()
                    .border(Color.yellow.opacity(0.7), width: 1)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color(white: 0.22).ignoresSafeArea())
        } else {
            content()
        }
    }
}

/// What the system says about the space the app has — the numbers the
/// adaptive layouts are driven by.
private struct DemoInfoOverlay: View {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let lines: [String] = [
                "safe area \(Int(geo.size.width))x\(Int(geo.size.height))",
                "insets t\(Int(insets.top)) b\(Int(insets.bottom)) l\(Int(insets.leading)) r\(Int(insets.trailing))",
                "size class h:\(Self.name(horizontal)) v:\(Self.name(vertical))",
            ]
            let _ = DemoSnapshot.note(lines, section: "1 layout")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                }
                if #available(iOS 27.1, *) {
                    DemoRegionInfo(proxy: geo)
                } else {
                    Text(verbatim: "regions: needs iOS 27.1")
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(6)
            .background(Color.yellow.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private static func name(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .regular: return "regular"
        case .compact: return "compact"
        default: return "?"
        }
    }
}

@available(iOS 27.1, *)
private struct DemoRegionInfo: View {
    let proxy: GeometryProxy
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        let lines: [String] = regionLines
        let _ = DemoSnapshot.note(lines, section: "2 regions")
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(verbatim: line)
        }
    }

    private var regionLines: [String] {
        var lines: [String] = ["vertical bars: " + edgeName]
        let divisions = proxy.reservedRegions(kind: .division, options: .includeInactive)
        if divisions.isEmpty {
            lines.append("fold: none")
        }
        for region in divisions {
            lines.append("fold " + Self.describe(region.frame) + (region.isActive ? " active" : " inactive"))
        }
        for region in proxy.reservedRegions(kind: .occlusion, options: .includeInactive) {
            lines.append("camera " + Self.describe(region.frame) + (region.isActive ? " active" : " inactive"))
        }
        return lines
    }

    private var edgeName: String {
        switch verticalEdge {
        case .leading?: return "leading"
        case .trailing?: return "trailing"
        default: return "none"
        }
    }

    private static func describe(_ frame: CGRect) -> String {
        "x\(Int(frame.minX)) y\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }
}

// MARK: - Snapshots

/// Saves a picture of the app's own windows where a script can collect it.
/// `simctl io screenshot` is the usual way to photograph a simulator, but it
/// failed on every attempt against iPhone Duo's two displays; drawing the
/// windows from inside the app works wherever the app runs. (It shows what
/// the app draws — not the system's status bar or the display's corners.)
@MainActor
enum DemoSnapshot {
    /// What the info overlay is currently showing, by section.
    private static var notes: [String: [String]] = [:]

    static func note(_ lines: [String], section: String) {
        notes[section] = lines
    }

    static func save(named name: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let windows = scene.windows
            .filter { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
        guard let canvas = windows.map(\.frame).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2    // plenty to judge a layout, and keeps the files small
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: canvas, format: format).image { context in
            UIColor.black.setFill()
            context.fill(canvas)
            for window in windows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
            }
        }

        let safeName = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("demo-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let landscape = canvas.width > canvas.height
        var text: [String] = ["window \(Int(canvas.width))x\(Int(canvas.height)) pt, " + (landscape ? "landscape" : "portrait")]
        for section in notes.keys.sorted() {
            text.append(contentsOf: notes[section] ?? [])
        }
        // The text first: the script takes the picture's arrival as "done".
        let report = text.joined(separator: "\n") + "\n"
        try? report.write(to: folder.appendingPathComponent(safeName + ".txt"), atomically: true, encoding: .utf8)
        try? image.jpegData(compressionQuality: 0.82)?
            .write(to: folder.appendingPathComponent(safeName + ".jpg"), options: .atomic)
    }
}

// MARK: - Sample data

enum DemoData {

    static func plan(equipment: Equipment, settings: SettingsStore, endurance: Bool = false) -> WorkoutPlan {
        let input = GeneratorInput(
            equipment: equipment,
            machine: settings.machine(for: equipment),
            level: .intermediate,
            minutes: endurance ? 30 : 20,
            vibe: .auto,
            progression: 2,
            sessionCount: 0,
            hardSessionsSinceEasy: 0,
            maxHR: settings.maxHR,
            restingHR: 56,
            age: 34)
        return endurance ? EnduranceGenerator.makePlan(input) : WorkoutGenerator.makePlan(input)
    }

    /// An engine frozen in the requested state — see `WorkoutEngine.debugFreeze`.
    static func engine(for demo: DemoMode, settings: SettingsStore) -> WorkoutEngine {
        let endurance = demo.state == "endurance"
        let plan = DemoData.plan(equipment: demo.equipment, settings: settings, endurance: endurance)
        let engine = WorkoutEngine(plan: plan)
        engine.maxHR = settings.maxHR
        engine.machine = settings.machine(for: demo.equipment)

        let phases = plan.phases
        let last = phases.count - 1
        let efforts = phases.indices.filter { phases[$0].kind == .work }
        let recoveries = phases.indices.filter { phases[$0].kind == .recover }
        // The third effort — far enough in for a real heart-rate trace.
        let effort = efforts.count > 2 ? efforts[2] : (efforts.first ?? min(1, last))
        let recovery = recoveries.count > 2 ? recoveries[2] : (recoveries.first ?? max(0, effort - 1))

        func rates(through index: Int, remaining: Double) -> [Double] {
            DemoData.trace(for: plan, through: index, remaining: remaining)
        }

        if demo.screen == "summary" {
            engine.debugFinish(heartRates: rates(through: last, remaining: 0))
            return engine
        }
        switch demo.state {
        case "warning":
            // Six seconds before a step up: the amber "get ready" state.
            engine.debugFreeze(phase: recovery, remaining: 6, heartRates: rates(through: recovery, remaining: 6))
        case "recover":
            engine.debugFreeze(phase: recovery, remaining: 41, heartRates: rates(through: recovery, remaining: 41))
        case "suggestion":
            let offer = LiveCoach.Suggestion(
                id: UUID(),
                trigger: .overBand,
                steps: -1,
                anchorIndex: effort,
                message: "Running hot — ease the remaining efforts back",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(3600))
            engine.debugFreeze(phase: effort, remaining: 14, heartRates: rates(through: effort, remaining: 14),
                               suggestion: offer)
        case "paused":
            engine.debugFreeze(phase: effort, remaining: 23, heartRates: rates(through: effort, remaining: 23),
                               paused: true)
        case "overtime":
            engine.debugFreeze(phase: last, remaining: 0, heartRates: rates(through: last, remaining: 0),
                               overtime: 75)
        case "endurance":
            let steady = min(1, last)
            let remaining = phases[steady].seconds * 0.6
            engine.debugFreeze(phase: steady, remaining: remaining, heartRates: rates(through: steady, remaining: remaining))
        default:
            engine.debugFreeze(phase: effort, remaining: 23, heartRates: rates(through: effort, remaining: 23),
                               coachLine: "Right in the zone — hold this")
        }
        return engine
    }

    /// A plausible heart-rate curve for the plan up to a point: one reading
    /// every five seconds, chasing each phase's typical heart rate.
    static func trace(for plan: WorkoutPlan, through index: Int, remaining: Double) -> [Double] {
        var bpm = 96.0
        var samples: [Double] = []
        for (position, phase) in plan.phases.enumerated() where position <= index {
            let target: Double
            switch phase.kind {
            case .warmup: target = 118
            case .work: target = 172
            case .recover: target = 133
            case .steady: target = 139
            case .cooldown: target = 112
            }
            let seconds = position == index ? max(0, phase.seconds - remaining) : phase.seconds
            var elapsed = 0.0
            while elapsed < seconds {
                bpm += (target - bpm) * 0.09
                samples.append((bpm + sin(Double(samples.count) * 0.9) * 1.5).rounded())
                elapsed += 5
            }
        }
        return samples
    }

    /// Fills the store with a few weeks of finished sessions; returns the
    /// most recent one.
    @discardableResult
    static func seed(into context: ModelContext, settings: SettingsStore) -> WorkoutSession? {
        struct Spec {
            var daysAgo: Double
            var equipment: Equipment
            var minutes: Int
            var rpe: Int
            var endurance: Bool
        }
        let specs = [
            Spec(daysAgo: 0.9, equipment: .treadmill, minutes: 20, rpe: 6, endurance: false),
            Spec(daysAgo: 3.1, equipment: .bike, minutes: 25, rpe: 7, endurance: false),
            Spec(daysAgo: 5.2, equipment: .treadmill, minutes: 30, rpe: 5, endurance: true),
            Spec(daysAgo: 8.0, equipment: .treadmill, minutes: 20, rpe: 8, endurance: false),
            Spec(daysAgo: 11.3, equipment: .outdoor, minutes: 15, rpe: 6, endurance: false),
            Spec(daysAgo: 15.0, equipment: .bike, minutes: 30, rpe: 7, endurance: false),
            Spec(daysAgo: 19.4, equipment: .treadmill, minutes: 25, rpe: 6, endurance: false),
        ]
        let grades = [
            SessionObjectives.Line(verdict: .met,
                                   title: "7:40 at ≥82% of max heart rate",
                                   detail: "A full dose of the high-intensity stimulus this session was built for."),
            SessionObjectives.Line(verdict: .partial,
                                   title: "5 of 8 efforts reached the target zone",
                                   detail: "Some efforts stopped short of the zone — hold each one a touch harder or longer."),
            SessionObjectives.Line(verdict: .met,
                                   title: "−27 bpm one minute after the last effort",
                                   detail: "A fast fall-off after the last effort — a strong fitness marker."),
        ]

        let now = Date()
        var newest: WorkoutSession? = nil
        for (index, spec) in specs.enumerated() {
            let machine = settings.machine(for: spec.equipment)
            let input = GeneratorInput(
                equipment: spec.equipment,
                machine: machine,
                level: .intermediate,
                minutes: spec.minutes,
                vibe: .auto,
                progression: Double(specs.count - index) * 0.5,
                sessionCount: index,
                hardSessionsSinceEasy: 0,
                maxHR: settings.maxHR)
            let plan = spec.endurance ? EnduranceGenerator.makePlan(input) : WorkoutGenerator.makePlan(input)
            let start = now.addingTimeInterval(-spec.daysAgo * 86400)
            let result = WorkoutEngine.buildResult(
                plan: plan,
                startDate: start,
                endDate: start.addingTimeInterval(plan.totalSeconds),
                appliedTargets: plan.phases.map(\.target),
                actualSeconds: plan.phases.map(\.seconds),
                machine: machine,
                weightKg: settings.value.weightKg,
                avgHeartRate: 146 + Double(index),
                maxHeartRate: 174 + Double(index % 3),
                avgWorkHeartRate: 164,
                hrRecovery: spec.endurance ? nil : 27,
                heartRateSamples: [],
                endedEarly: false)
            let session = WorkoutSession(result: result)
            session.rpe = spec.rpe
            session.savedToHealth = true
            session.nextTimeNote = "Right in the sweet spot. Small bump next time."
            if !spec.endurance {
                session.objectivesData = (try? JSONEncoder().encode(grades)) ?? Data()
            }
            context.insert(session)
            if newest == nil { newest = session }
        }
        try? context.save()
        return newest
    }
}
#endif
