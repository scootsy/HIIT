import Foundation
import HealthKit
import Observation
import os

/// All Apple Health integration: authorization, pulling a profile snapshot
/// (age / weight / height / resting HR) to personalize workouts, streaming
/// live heart-rate samples during a session, reading long-term fitness signals
/// (VO₂max, resting-HR trend), and saving finished workouts back.
///
/// Live heart rate requires a source that writes to Health in near-real-time —
/// in practice an Apple Watch with a workout running, or a paired chest strap.
/// Everything degrades gracefully when no data is available.
@Observable
final class HealthKitManager {

    static let isAvailable = HKHealthStore.isHealthDataAvailable()

    struct ProfileSnapshot {
        var age: Int? = nil
        var weightKg: Double? = nil
        var heightCm: Double? = nil
        var restingHR: Double? = nil
    }

    var liveHeartRate: Double? = nil
    var liveHeartRateDate: Date? = nil

    static let vo2MaxUnit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo))
        .unitDivided(by: .minute())

    static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    private let store = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery? = nil

    private func quantityType(_ id: HKQuantityTypeIdentifier) -> HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: id)
    }

    // MARK: - Authorization

    /// Returns nil on success, or a user-facing explanation of why the
    /// permission sheet could not be shown. The most common failure is a
    /// sideloaded build signed without the HealthKit capability (SideStore
    /// never asks Apple for it) — iOS then rejects the request without ever
    /// presenting the sheet.
    func requestAuthorization() async -> String? {
        guard Self.isAvailable else {
            return "Health data isn't available on this device."
        }
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = [HKObjectType.workoutType()]
        let readIDs: [HKQuantityTypeIdentifier] = [.heartRate, .restingHeartRate, .bodyMass, .height, .activeEnergyBurned, .vo2Max]
        for id in readIDs {
            if let type = quantityType(id) { read.insert(type) }
        }
        let shareIDs: [HKQuantityTypeIdentifier] = [.activeEnergyBurned, .distanceWalkingRunning, .heartRate]
        for id in shareIDs {
            if let type = quantityType(id) { share.insert(type) }
        }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            read.insert(dob)
        }
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            return nil
        } catch {
            let message = (error as NSError).localizedDescription
            AppLog.health.error("authorization request failed: \(message, privacy: .public)")
            // The entitlement identifier itself is never localized, so match
            // it too — the bare word "entitlement" only appears in English
            // error text.
            if message.localizedCaseInsensitiveContains("entitlement")
                || message.contains("com.apple.developer.healthkit") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                return "This install of HIIT Coach (\(version)) doesn't include Apple's HealthKit permission, so iOS can't show the Health sheet. \(SigningProfile.healthKitDiagnosis(SigningProfile.embedded)) Nothing else is affected: type your age and weight in Settings, and pair a Bluetooth heart-rate strap for live heart rate. The project's README on GitHub explains how to get an install that includes Health."
            }
            return message
        }
    }

    // MARK: - Profile

    func fetchProfile() async -> ProfileSnapshot {
        var snapshot = ProfileSnapshot()
        guard Self.isAvailable else { return snapshot }

        if let components = try? store.dateOfBirthComponents(),
           let birthDate = Calendar.current.date(from: components) {
            snapshot.age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        }
        snapshot.weightKg = await latestQuantity(.bodyMass, unit: .gramUnit(with: .kilo))
        if let meters = await latestQuantity(.height, unit: .meter()) {
            snapshot.heightCm = meters * 100
        }
        snapshot.restingHR = await latestQuantity(.restingHeartRate, unit: Self.bpmUnit)
        return snapshot
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = quantityType(id) else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    AppLog.health.error("read \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    // MARK: - Fitness signal series (VO₂max, resting-HR trend)

    struct SamplePoint: Identifiable {
        let id: Date
        let value: Double
        var date: Date { id }
    }

    func fetchSeries(_ id: HKQuantityTypeIdentifier, unit: HKUnit, daysBack: Int) async -> [SamplePoint] {
        guard Self.isAvailable, let type = quantityType(id) else { return [] }
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    AppLog.health.error("series read \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                let points = (samples ?? [])
                    .compactMap { $0 as? HKQuantitySample }
                    .map { SamplePoint(id: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    // MARK: - Live heart rate

    func startHeartRateUpdates() {
        stopHeartRateUpdates()
        guard Self.isAvailable, let type = quantityType(.heartRate) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-60), end: nil, options: [])
        let unit = Self.bpmUnit

        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            let quantitySamples = samples?.compactMap { $0 as? HKQuantitySample } ?? []
            guard let latest = quantitySamples.max(by: { $0.endDate < $1.endDate }) else { return }
            let bpm = latest.quantity.doubleValue(for: unit)
            DispatchQueue.main.async {
                self?.liveHeartRate = bpm
                self?.liveHeartRateDate = latest.endDate
            }
        }

        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        store.execute(query)
        hrQuery = query
    }

    func stopHeartRateUpdates() {
        if let query = hrQuery {
            store.stop(query)
            hrQuery = nil
        }
    }

    // MARK: - Saving workouts

    enum WorkoutSaveOutcome {
        case saved
        /// Authorized but the save failed — worth telling the user about.
        case failed
        /// Sharing was never granted (user skipped or denied Health) — the
        /// summary shouldn't dress an expected state up as an error.
        case notAuthorized
    }

    func saveWorkout(result: SessionResult) async -> WorkoutSaveOutcome {
        await saveWorkout(equipment: result.plan.equipment,
                          start: result.startDate,
                          end: result.endDate,
                          kilocalories: result.estimatedCalories,
                          distanceMeters: result.estimatedDistanceMeters,
                          heartRateSamples: result.heartRateSamples)
    }

    /// Retry path for a stored session whose original export failed. The
    /// strap heart-rate trace isn't persisted with the session, so a retried
    /// export carries the workout, energy, and distance but no HR samples.
    func saveWorkout(session: WorkoutSession) async -> WorkoutSaveOutcome {
        await saveWorkout(equipment: session.equipment,
                          start: session.date,
                          end: session.date.addingTimeInterval(max(1, session.totalSeconds)),
                          kilocalories: session.estimatedCalories,
                          distanceMeters: session.estimatedDistanceMeters,
                          heartRateSamples: [])
    }

    /// True when we may write this sample type. Health treats "not asked yet"
    /// and "denied" separately from authorized; adding an unauthorized sample
    /// makes the whole builder throw, which used to sink the entire workout
    /// export because one toggle (e.g. Heart Rate) was off.
    private func sharingAuthorized(_ id: HKQuantityTypeIdentifier) -> Bool {
        guard let type = quantityType(id) else { return false }
        return store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private func saveWorkout(equipment: Equipment,
                             start: Date,
                             end: Date,
                             kilocalories: Double,
                             distanceMeters: Double,
                             heartRateSamples: [HRSample]) async -> WorkoutSaveOutcome {
        guard Self.isAvailable else { return .notAuthorized }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            return .notAuthorized
        }
        let configuration = HKWorkoutConfiguration()
        switch equipment {
        case .bike:
            configuration.activityType = .cycling
        case .treadmill, .outdoor:
            configuration.activityType = .running
        }
        configuration.locationType = equipment == .outdoor ? .outdoor : .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            // Attach only the sample types the user actually shares — the
            // workout itself must still save when individual toggles are off.
            var samples: [HKSample] = []
            if kilocalories > 1, sharingAuthorized(.activeEnergyBurned), let type = quantityType(.activeEnergyBurned) {
                samples.append(HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kilocalories),
                    start: start,
                    end: end))
            }
            if distanceMeters > 10,
               equipment != .bike,
               sharingAuthorized(.distanceWalkingRunning),
               let type = quantityType(.distanceWalkingRunning) {
                samples.append(HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                    start: start,
                    end: end))
            }
            if !heartRateSamples.isEmpty, sharingAuthorized(.heartRate), let type = quantityType(.heartRate) {
                let hrSamples = heartRateSamples.map { sample in
                    HKQuantitySample(
                        type: type,
                        quantity: HKQuantity(unit: Self.bpmUnit, doubleValue: sample.bpm),
                        start: sample.date,
                        end: sample.date)
                }
                samples.append(contentsOf: hrSamples)
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }
            try await builder.addMetadata([HKMetadataKeyIndoorWorkout: equipment != .outdoor])
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            return .saved
        } catch {
            AppLog.health.error("workout export failed: \((error as NSError).localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
