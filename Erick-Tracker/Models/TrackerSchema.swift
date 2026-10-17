import Foundation
import SwiftData

nonisolated enum SetKind: String, Codable, CaseIterable, Identifiable {
    case warmup, feeder, working, topSet, backOff, dropSet

    var id: String { rawValue }
    var label: String {
        switch self {
        case .warmup: "Aquecimento"
        case .feeder: "Feeder"
        case .working: "Trabalho"
        case .topSet: "Top set"
        case .backOff: "Back-off"
        case .dropSet: "Drop set"
        }
    }
    var countsTowardVolume: Bool { self != .warmup && self != .feeder }
    var isNumbered: Bool { countsTowardVolume }
}

nonisolated enum IntensityScale: String, Codable, CaseIterable, Identifiable {
    case rir, rpe
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

nonisolated enum ExerciseKind: String, Codable, CaseIterable, Identifiable {
    case compound, isolation
    var id: String { rawValue }
    var label: String { self == .compound ? "Composto" : "Isolado" }
}

enum TrackerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [Program.self, Exercise.self, WorkoutTemplate.self, WorkoutItem.self, SetTemplate.self]
    }

    @Model final class Program {
        @Attribute(.unique) var id: UUID
        var name: String
        var position: Int
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .nullify, inverse: \WorkoutTemplate.program)
        var workouts: [WorkoutTemplate] = []

        init(name: String, position: Int = 0) {
            id = UUID(); self.name = name; self.position = position
            createdAt = .now; updatedAt = .now
        }
    }

    @Model final class Exercise {
        @Attribute(.unique) var id: UUID
        var name: String
        var primaryMuscle: String
        var secondaryMuscles: String
        var equipment: String
        var movementPattern: String
        var kindRawValue: String
        var notes: String
        var isArchived: Bool
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .nullify, inverse: \WorkoutItem.exercise)
        var items: [WorkoutItem] = []

        var kind: ExerciseKind {
            get { ExerciseKind(rawValue: kindRawValue) ?? .compound }
            set { kindRawValue = newValue.rawValue }
        }

        init(name: String, primaryMuscle: String = "", secondaryMuscles: String = "",
             equipment: String = "", movementPattern: String = "",
             kind: ExerciseKind = .compound, notes: String = "") {
            id = UUID(); self.name = name; self.primaryMuscle = primaryMuscle
            self.secondaryMuscles = secondaryMuscles; self.equipment = equipment
            self.movementPattern = movementPattern; kindRawValue = kind.rawValue
            self.notes = notes; isArchived = false; createdAt = .now; updatedAt = .now
        }
    }

    @Model final class WorkoutTemplate {
        @Attribute(.unique) var id: UUID
        var name: String
        var notes: String
        var position: Int
        var isArchived: Bool
        var createdAt: Date
        var updatedAt: Date
        var program: Program?
        @Relationship(deleteRule: .cascade, inverse: \WorkoutItem.workout)
        var items: [WorkoutItem] = []

        var orderedItems: [WorkoutItem] {
            items.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        }
        var workingSetCount: Int { items.reduce(0) { $0 + $1.sets.filter(\.kind.countsTowardVolume).count } }
        var totalSetCount: Int { items.reduce(0) { $0 + $1.sets.count } }
        var muscleGroups: String {
            Array(Set(items.compactMap(\.exercise).map(\.primaryMuscle).filter { !$0.isEmpty }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
        }
        var estimatedMinutes: Int {
            let seconds = items.reduce(0) { result, item in
                result + item.sets.reduce(0) { $0 + 40 + $1.effectiveRestSeconds }
            }
            return Int((Double(seconds) / 60).rounded())
        }

        init(name: String, program: Program? = nil, position: Int = 0) {
            id = UUID(); self.name = name; self.program = program; self.position = position
            notes = ""; isArchived = false; createdAt = .now; updatedAt = .now
        }
    }

    @Model final class WorkoutItem {
        @Attribute(.unique) var id: UUID
        var position: Int
        var restSeconds: Int
        var repRange: String
        var intensityScaleRawValue: String
        var intensityTarget: String
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        var workout: WorkoutTemplate?
        var exercise: Exercise?
        @Relationship(deleteRule: .cascade, inverse: \SetTemplate.item)
        var sets: [SetTemplate] = []

        var intensityScale: IntensityScale {
            get { IntensityScale(rawValue: intensityScaleRawValue) ?? .rir }
            set { intensityScaleRawValue = newValue.rawValue }
        }
        var orderedSets: [SetTemplate] {
            sets.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        }
        func number(for set: SetTemplate) -> Int? {
            guard set.kind.isNumbered else { return nil }
            return orderedSets.prefix { $0.id != set.id }.filter(\.kind.isNumbered).count + 1
        }

        init(exercise: Exercise, position: Int = 0, restSeconds: Int = 120,
             intensityScale: IntensityScale = .rir, intensityTarget: String = "2") {
            id = UUID(); self.exercise = exercise; self.position = position
            self.restSeconds = restSeconds; self.intensityScaleRawValue = intensityScale.rawValue
            self.intensityTarget = intensityTarget; repRange = ""; notes = ""
            createdAt = .now; updatedAt = .now
        }
    }

    @Model final class SetTemplate {
        @Attribute(.unique) var id: UUID
        var position: Int
        var kindRawValue: String
        var reps: String
        var load: String
        var intensity: String
        var restSecondsOverride: Int?
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        var item: WorkoutItem?

        var kind: SetKind {
            get { SetKind(rawValue: kindRawValue) ?? .working }
            set { kindRawValue = newValue.rawValue }
        }
        var effectiveRestSeconds: Int { restSecondsOverride ?? item?.restSeconds ?? 120 }

        init(position: Int = 0, kind: SetKind = .working, reps: String = "",
             load: String = "", intensity: String = "", restSecondsOverride: Int? = nil,
             notes: String = "") {
            id = UUID(); self.position = position; kindRawValue = kind.rawValue
            self.reps = reps; self.load = load; self.intensity = intensity
            self.restSecondsOverride = restSecondsOverride; self.notes = notes
            createdAt = .now; updatedAt = .now
        }
    }
}

typealias Program = TrackerSchemaV1.Program
typealias Exercise = TrackerSchemaV1.Exercise
typealias WorkoutTemplate = TrackerSchemaV1.WorkoutTemplate
typealias WorkoutItem = TrackerSchemaV1.WorkoutItem
typealias SetTemplate = TrackerSchemaV1.SetTemplate

enum TrackerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrackerSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
