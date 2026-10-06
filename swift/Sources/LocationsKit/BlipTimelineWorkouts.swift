import Foundation

public struct BlipTimelineWorkout: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let startDate: Date
    public let endDate: Date
    public let totalEnergyKilocalories: Double?
    public let totalDistanceMeters: Double?
    public let sourceName: String
    public let isIndoor: Bool?

    public init(
        id: String,
        title: String,
        systemImage: String,
        startDate: Date,
        endDate: Date,
        totalEnergyKilocalories: Double? = nil,
        totalDistanceMeters: Double? = nil,
        sourceName: String,
        isIndoor: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.startDate = startDate
        self.endDate = endDate
        self.totalEnergyKilocalories = totalEnergyKilocalories
        self.totalDistanceMeters = totalDistanceMeters
        self.sourceName = sourceName
        self.isIndoor = isIndoor
    }

    public var duration: TimeInterval {
        max(0, endDate.timeIntervalSince(startDate))
    }
}

enum BlipTimelineWorkoutMatcher {
    static func workouts(
        for entry: BlipTimelineEntry,
        in day: BlipTimelineDay,
        workouts: [BlipTimelineWorkout]
    ) -> [BlipTimelineWorkout] {
        let entries = day.orderedEntries
        guard let entryIndex = entries.firstIndex(where: { $0.id == entry.id }) else { return [] }

        return workouts.filter { workout in
            bestEntryIndex(for: workout, entries: entries, day: day) == entryIndex
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private static func bestEntryIndex(
        for workout: BlipTimelineWorkout,
        entries: [BlipTimelineEntry],
        day: BlipTimelineDay
    ) -> Int? {
        guard !entries.isEmpty else { return nil }
        let dayEnd = calendar(for: day).date(byAdding: .day, value: 1, to: day.date)
            ?? workout.endDate

        var best: (index: Int, overlap: TimeInterval, entryDuration: TimeInterval)?
        for index in entries.indices {
            let entry = entries[index]
            let nextStart = entries.indices.contains(index + 1) ? entries[index + 1].startDate : nil
            let entryEnd = entry.endDate ?? nextStart ?? dayEnd
            let overlap = min(entryEnd, workout.endDate)
                .timeIntervalSince(max(entry.startDate, workout.startDate))
            guard overlap > 0 else { continue }

            let entryDuration = max(0, entryEnd.timeIntervalSince(entry.startDate))
            if let current = best {
                if overlap > current.overlap
                    || (overlap == current.overlap && entryDuration < current.entryDuration) {
                    best = (index, overlap, entryDuration)
                }
            } else {
                best = (index, overlap, entryDuration)
            }
        }
        return best?.index
    }

    private static func calendar(for day: BlipTimelineDay) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .autoupdatingCurrent
        return calendar
    }
}

#if os(iOS) && canImport(HealthKit)
import HealthKit

final class BlipTimelineHealthWorkoutSource: @unchecked Sendable {
    private let healthStore = HKHealthStore()

    func workouts(in interval: DateInterval) async throws -> [BlipTimelineWorkout] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        try await healthStore.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])

        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: [.strictStartDate]
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: healthStore).map(Self.timelineWorkout)
    }

    private static func timelineWorkout(_ workout: HKWorkout) -> BlipTimelineWorkout {
        let presentation = presentation(for: workout.workoutActivityType)
        let activeEnergyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        let activeEnergy = activeEnergyType
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .kilocalorie()) }
        return BlipTimelineWorkout(
            id: workout.uuid.uuidString.lowercased(),
            title: presentation.title,
            systemImage: presentation.systemImage,
            startDate: workout.startDate,
            endDate: workout.endDate,
            totalEnergyKilocalories: activeEnergy,
            totalDistanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
            sourceName: workout.sourceRevision.source.name,
            isIndoor: workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool
        )
    }

    private static func presentation(
        for activity: HKWorkoutActivityType
    ) -> (title: String, systemImage: String) {
        switch activity {
        case .walking: ("Walking", "figure.walk")
        case .running: ("Running", "figure.run")
        case .cycling: ("Cycling", "figure.outdoor.cycle")
        case .hiking: ("Hiking", "figure.hiking")
        case .swimming: ("Swimming", "figure.pool.swim")
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            ("Strength training", "dumbbell.fill")
        case .highIntensityIntervalTraining: ("HIIT", "figure.highintensity.intervaltraining")
        case .yoga: ("Yoga", "figure.yoga")
        case .pilates: ("Pilates", "figure.pilates")
        case .rowing: ("Rowing", "figure.rower")
        case .elliptical: ("Elliptical", "figure.elliptical")
        case .stairClimbing: ("Stair climbing", "figure.stair.stepper")
        case .soccer: ("Football", "figure.soccer")
        case .tennis: ("Tennis", "figure.tennis")
        case .golf: ("Golf", "figure.golf")
        case .dance: ("Dance", "figure.dance")
        case .coreTraining: ("Core training", "figure.core.training")
        case .crossTraining: ("Cross training", "figure.cross.training")
        case .cooldown: ("Cooldown", "figure.cooldown")
        case .flexibility: ("Flexibility", "figure.flexibility")
        case .mixedCardio: ("Mixed cardio", "figure.mixed.cardio")
        case .pickleball: ("Pickleball", "figure.pickleball")
        default: ("Workout", "figure.mixed.cardio")
        }
    }
}
#endif
