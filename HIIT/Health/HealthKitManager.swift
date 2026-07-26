import Foundation
import HealthKit
import Observation

/// All Apple Health integration: authorization, pulling a profile snapshot
/// (age / weight / height / resting HR) to personalize workouts, streaming
/// live heart-rate samples during a session, and saving finished workouts back.
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

    private let store = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery? = nil

    private func quantityType(_ id: HKQuantityTypeIdentifier) -> HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: id)
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        var read: Set<HKObjectType> = [HKObjectType.workoutType()]
        let readIDs: [HKQuantityTypeIdentifier] = [.heartRate, .restingHeartRate, .bodyMass, .height, .activeEnergyBurned]
        for id in readIDs {
            if let type = quantityType(id) { read.insert(type) }
        }
        let shareIDs: [HKQuantityTypeIdentifier] = [.activeEnergyBurned, .distanceWalkingRunning, .distanceCycling]
        for id in shareIDs {
            if let type = quantityType(id) { share.insert(type) }
        }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            read.insert(dob)
        }
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            return true
        } catch {
            return false
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
        snapshot.restingHR = await latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        return snapshot
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = quantityType(id) else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    // MARK: - Live heart rate

    func startHeartRateUpdates() {
        stopHeartRateUpdates()
        guard Self.isAvailable, let type = quantityType(.heartRate) else { return }
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-60), end: nil, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())

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

    func saveWorkout(result: SessionResult) async -> Bool {
        guard Self.isAvailable else { return false }
        let configuration = HKWorkoutConfiguration()
        switch result.plan.equipment {
        case .bike:
            configuration.activityType = .cycling
        case .treadmill, .outdoor:
            configuration.activityType = .running
        }
        configuration.locationType = result.plan.equipment == .outdoor ? .outdoor : .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: result.startDate)
            var samples: [HKSample] = []
            if result.estimatedCalories > 1, let type = quantityType(.activeEnergyBurned) {
                samples.append(HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: result.estimatedCalories),
                    start: result.startDate,
                    end: result.endDate))
            }
            if result.estimatedDistanceMeters > 10,
               result.plan.equipment != .bike,
               let type = quantityType(.distanceWalkingRunning) {
                samples.append(HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: .meter(), doubleValue: result.estimatedDistanceMeters),
                    start: result.startDate,
                    end: result.endDate))
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }
            try await builder.addMetadata([HKMetadataKeyIndoorWorkout: result.plan.equipment != .outdoor])
            try await builder.endCollection(at: result.endDate)
            _ = try await builder.finishWorkout()
            return true
        } catch {
            return false
        }
    }
}
