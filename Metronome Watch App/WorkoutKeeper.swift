//
//  WorkoutKeeper.swift
//  Metronome
//
//  Created by Mitsuitou on 2025/9/8.
//

import Foundation
import HealthKit

final class WorkoutKeeper: NSObject, ObservableObject {
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    @Published private(set) var isActive: Bool = false

    func authorizeIfNeeded() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types: Set = [HKObjectType.workoutType()]
        try await store.requestAuthorization(toShare: types, read: types)
    }

    func start() throws {
        // 避免重复开启
        guard !isActive else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .other          // 任选合适类型（例如 .other, .traditionalStrengthTraining 等）
        config.locationType = .unknown

        session = try HKWorkoutSession(healthStore: store, configuration: config)
        builder = session?.associatedWorkoutBuilder()
        builder?.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)

        session?.startActivity(with: Date())
        builder?.beginCollection(withStart: Date(), completion: { _,_ in })

        isActive = true
    }

    func stop() {
        guard isActive else { return }
        session?.end()
        builder?.endCollection(withEnd: Date(), completion: { _,_ in })
        builder?.finishWorkout(completion: { _,_ in })
        session = nil
        builder = nil
        isActive = false
    }
}
