import Foundation
import SwiftData

nonisolated enum SnapshotCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

nonisolated struct ProgramSnapshot: Codable {
    var id: UUID; var name: String; var position: Int; var createdAt: Date; var updatedAt: Date
}
nonisolated struct ExerciseSnapshot: Codable {
    var id: UUID; var name: String; var primaryMuscle: String; var secondaryMuscles: String
    var equipment: String; var movementPattern: String; var kind: ExerciseKind; var notes: String
    var isArchived: Bool; var createdAt: Date; var updatedAt: Date
}
nonisolated struct PlannedSetSnapshot: Codable {
    var id: UUID; var position: Int; var kind: SetKind; var reps: String; var load: String
    var intensity: String; var restSecondsOverride: Int?; var notes: String
    var createdAt: Date; var updatedAt: Date
}
nonisolated struct PlannedItemSnapshot: Codable {
    var id: UUID; var exerciseID: UUID?; var exerciseName: String; var muscle: String
    var position: Int; var restSeconds: Int; var repRange: String
    var intensityScale: IntensityScale; var intensityTarget: String; var notes: String
    var createdAt: Date; var updatedAt: Date; var sets: [PlannedSetSnapshot]
}
nonisolated struct WorkoutSnapshot: Codable {
    var id: UUID; var name: String; var programID: UUID?; var notes: String; var position: Int
    var isArchived: Bool; var createdAt: Date; var updatedAt: Date; var items: [PlannedItemSnapshot]
}
nonisolated struct SegmentSnapshot: Codable {
    var id: UUID; var position: Int; var reps: Int?; var loadKg: String?
}
nonisolated struct LoggedSetSnapshot: Codable {
    var id: UUID; var sourceSetID: UUID?; var position: Int; var kind: SetKind
    var prescribedKind: SetKind; var prescribedReps: String; var prescribedLoad: String
    var prescribedIntensity: String; var intensityScale: IntensityScale; var intensity: String
    var restSeconds: Int; var notes: String; var status: LoggedSetStatus
    var completedAt: Date?; var segments: [SegmentSnapshot]
}
nonisolated struct LoggedExerciseSnapshot: Codable {
    var id: UUID; var sourceItemID: UUID?; var exerciseID: UUID?; var prescribedName: String
    var name: String; var muscle: String; var position: Int; var notes: String
    var sets: [LoggedSetSnapshot]
}
nonisolated struct SessionSnapshot: Codable {
    var id: UUID; var sourceTemplateID: UUID?; var name: String; var prescription: Data
    var status: SessionStatus; var startedAt: Date; var endedAt: Date?; var pausedAt: Date?
    var pausedSeconds: Double; var timezoneID: String; var deviceID: String; var notes: String
    var createdAt: Date; var updatedAt: Date; var restStartedAt: Date?; var restEndsAt: Date?
    var pausedRestSeconds: Double?; var currentExerciseID: UUID?; var exercises: [LoggedExerciseSnapshot]
}

@MainActor enum Snapshots {
    static func program(_ p: Program) -> ProgramSnapshot {
        .init(id: p.id, name: p.name, position: p.position, createdAt: p.createdAt, updatedAt: p.updatedAt)
    }
    static func exercise(_ e: Exercise) -> ExerciseSnapshot {
        .init(id: e.id, name: e.name, primaryMuscle: e.primaryMuscle, secondaryMuscles: e.secondaryMuscles,
              equipment: e.equipment, movementPattern: e.movementPattern, kind: e.kind, notes: e.notes,
              isArchived: e.isArchived, createdAt: e.createdAt, updatedAt: e.updatedAt)
    }
    static func workout(_ w: WorkoutTemplate) -> WorkoutSnapshot {
        .init(id: w.id, name: w.name, programID: w.program?.id, notes: w.notes, position: w.position,
              isArchived: w.isArchived, createdAt: w.createdAt, updatedAt: w.updatedAt, items: w.orderedItems.map { i in
            .init(id: i.id, exerciseID: i.exercise?.id, exerciseName: i.exercise?.name ?? "Exercício",
                  muscle: i.exercise?.primaryMuscle ?? "", position: i.position, restSeconds: i.restSeconds,
                  repRange: i.repRange, intensityScale: i.intensityScale, intensityTarget: i.intensityTarget,
                  notes: i.notes, createdAt: i.createdAt, updatedAt: i.updatedAt, sets: i.orderedSets.map { s in
                .init(id: s.id, position: s.position, kind: s.kind, reps: s.reps, load: s.load,
                      intensity: s.intensity, restSecondsOverride: s.restSecondsOverride, notes: s.notes,
                      createdAt: s.createdAt, updatedAt: s.updatedAt)
            })
        })
    }
    static func session(_ s: WorkoutSession) -> SessionSnapshot {
        .init(id: s.id, sourceTemplateID: s.sourceTemplateID, name: s.name, prescription: s.prescription,
              status: s.status, startedAt: s.startedAt, endedAt: s.endedAt, pausedAt: s.pausedAt,
              pausedSeconds: s.pausedSeconds, timezoneID: s.timezoneID, deviceID: s.deviceID, notes: s.notes,
              createdAt: s.createdAt, updatedAt: s.updatedAt, restStartedAt: s.restStartedAt,
              restEndsAt: s.restEndsAt, pausedRestSeconds: s.pausedRestSeconds,
              currentExerciseID: s.currentExerciseID, exercises: s.orderedExercises.map { e in
            .init(id: e.id, sourceItemID: e.sourceItemID, exerciseID: e.exerciseID,
                  prescribedName: e.prescribedName, name: e.name, muscle: e.muscle, position: e.position,
                  notes: e.notes, sets: e.orderedSets.map { x in
                .init(id: x.id, sourceSetID: x.sourceSetID, position: x.position, kind: x.kind,
                      prescribedKind: SetKind(rawValue: x.prescribedKindRaw) ?? .working,
                      prescribedReps: x.prescribedReps, prescribedLoad: x.prescribedLoad,
                      prescribedIntensity: x.prescribedIntensity,
                      intensityScale: IntensityScale(rawValue: x.intensityScaleRaw) ?? .rir,
                      intensity: x.intensity, restSeconds: x.restSeconds, notes: x.notes,
                      status: x.status, completedAt: x.completedAt, segments: x.orderedSegments.map {
                    .init(id: $0.id, position: $0.position, reps: $0.reps, loadKg: $0.loadKg)
                })
            })
        })
    }
    static func all(in context: ModelContext) throws -> [(EntityKind, UUID, Data)] {
        var result: [(EntityKind, UUID, Data)] = []
        for p in try context.fetch(FetchDescriptor<Program>()) { result.append((.program, p.id, try SnapshotCodec.encode(program(p)))) }
        for e in try context.fetch(FetchDescriptor<Exercise>()) { result.append((.exercise, e.id, try SnapshotCodec.encode(exercise(e)))) }
        for w in try context.fetch(FetchDescriptor<WorkoutTemplate>()) { result.append((.workout, w.id, try SnapshotCodec.encode(workout(w)))) }
        for s in try context.fetch(FetchDescriptor<WorkoutSession>()) { result.append((.session, s.id, try SnapshotCodec.encode(session(s)))) }
        result += try ProgressSnapshots.all(in: context)
        return result.sorted { a, b in
            let kinds = EntityKind.allCases
            let ai = kinds.firstIndex(of: a.0)!, bi = kinds.firstIndex(of: b.0)!
            return ai == bi ? a.1.uuidString < b.1.uuidString : ai < bi
        }
    }

    static func apply(kind: EntityKind, id: UUID, payload: Data?, in c: ModelContext) throws {
        if [.bodyProfile, .bodyRecord, .sleep].contains(kind) {
            try ProgressSnapshots.apply(kind: kind, id: id, payload: payload, in: c); return
        }
        guard let payload else {
            switch kind {
            case .program:
                if let p = try c.fetch(FetchDescriptor<Program>()).first(where: { $0.id == id }) {
                    for w in p.workouts { w.program = nil }; c.delete(p)
                }
            case .exercise:
                if let e = try c.fetch(FetchDescriptor<Exercise>()).first(where: { $0.id == id }) { c.delete(e) }
            case .workout:
                if let w = try c.fetch(FetchDescriptor<WorkoutTemplate>()).first(where: { $0.id == id }) { c.delete(w) }
            case .session:
                if let s = try c.fetch(FetchDescriptor<WorkoutSession>()).first(where: { $0.id == id }) { c.delete(s) }
            default: throw SyncFailure.invalidResponse
            }
            return
        }
        switch kind {
        case .program:
            let d = try SnapshotCodec.decode(ProgramSnapshot.self, from: payload)
            let p = try c.fetch(FetchDescriptor<Program>()).first { $0.id == id } ?? Program(name: d.name)
            if p.modelContext == nil { c.insert(p) }; p.id = d.id; p.name = d.name
            p.position = d.position; p.createdAt = d.createdAt; p.updatedAt = d.updatedAt
        case .exercise:
            let d = try SnapshotCodec.decode(ExerciseSnapshot.self, from: payload)
            let e = try c.fetch(FetchDescriptor<Exercise>()).first { $0.id == id } ?? Exercise(name: d.name)
            if e.modelContext == nil { c.insert(e) }; e.id = d.id; e.name = d.name
            e.primaryMuscle = d.primaryMuscle; e.secondaryMuscles = d.secondaryMuscles
            e.equipment = d.equipment; e.movementPattern = d.movementPattern; e.kind = d.kind
            e.notes = d.notes; e.isArchived = d.isArchived; e.createdAt = d.createdAt; e.updatedAt = d.updatedAt
        case .workout:
            let d = try SnapshotCodec.decode(WorkoutSnapshot.self, from: payload)
            let w = try c.fetch(FetchDescriptor<WorkoutTemplate>()).first { $0.id == id } ?? WorkoutTemplate(name: d.name)
            if w.modelContext == nil { c.insert(w) }; w.id = d.id; w.name = d.name; w.notes = d.notes
            w.position = d.position; w.isArchived = d.isArchived; w.createdAt = d.createdAt; w.updatedAt = d.updatedAt
            w.program = try c.fetch(FetchDescriptor<Program>()).first { $0.id == d.programID }
            let old = w.items
            let desired = Set(d.items.map(\.id))
            for i in old where !desired.contains(i.id) { w.items.removeAll { $0.id == i.id }; c.delete(i) }
            let exercises = try c.fetch(FetchDescriptor<Exercise>())
            for x in d.items {
                guard let e = exercises.first(where: { $0.id == x.exerciseID }) else {
                    throw SnapshotError.missingExercise(x.exerciseName)
                }
                let i = old.first { $0.id == x.id } ?? WorkoutItem(exercise: e)
                if i.modelContext == nil { c.insert(i) }
                i.id = x.id; i.exercise = e; i.position = x.position; i.restSeconds = x.restSeconds
                i.intensityScale = x.intensityScale; i.intensityTarget = x.intensityTarget
                i.repRange = x.repRange; i.notes = x.notes
                i.createdAt = x.createdAt; i.updatedAt = x.updatedAt; i.workout = w
                let oldSets = i.sets; let desiredSets = Set(x.sets.map(\.id))
                for s in oldSets where !desiredSets.contains(s.id) { i.sets.removeAll { $0.id == s.id }; c.delete(s) }
                for y in x.sets {
                    let s = oldSets.first { $0.id == y.id } ?? SetTemplate()
                    if s.modelContext == nil { c.insert(s) }
                    s.id = y.id; s.position = y.position; s.kind = y.kind; s.reps = y.reps; s.load = y.load
                    s.intensity = y.intensity; s.restSecondsOverride = y.restSecondsOverride; s.notes = y.notes
                    s.createdAt = y.createdAt; s.updatedAt = y.updatedAt; s.item = i
                }
            }
        case .session:
            let d = try SnapshotCodec.decode(SessionSnapshot.self, from: payload)
            let s = try c.fetch(FetchDescriptor<WorkoutSession>()).first { $0.id == id }
                ?? WorkoutSession(name: d.name, prescription: d.prescription, deviceID: d.deviceID)
            if s.modelContext == nil { c.insert(s) }; s.id = d.id; s.sourceTemplateID = d.sourceTemplateID
            s.name = d.name; s.prescription = d.prescription; s.status = d.status; s.startedAt = d.startedAt
            s.endedAt = d.endedAt; s.pausedAt = d.pausedAt; s.pausedSeconds = d.pausedSeconds
            s.timezoneID = d.timezoneID; s.deviceID = d.deviceID; s.notes = d.notes
            s.createdAt = d.createdAt; s.updatedAt = d.updatedAt; s.restStartedAt = d.restStartedAt
            s.restEndsAt = d.restEndsAt; s.pausedRestSeconds = d.pausedRestSeconds; s.currentExerciseID = d.currentExerciseID
            let old = s.exercises; let desired = Set(d.exercises.map(\.id))
            for e in old where !desired.contains(e.id) { s.exercises.removeAll { $0.id == e.id }; c.delete(e) }
            for x in d.exercises {
                let e = old.first { $0.id == x.id } ?? ExerciseLog(name: x.name, position: x.position)
                if e.modelContext == nil { c.insert(e) }; e.id = x.id; e.name = x.name; e.position = x.position
                e.exerciseID = x.exerciseID; e.sourceItemID = x.sourceItemID
                e.prescribedName = x.prescribedName; e.muscle = x.muscle; e.notes = x.notes; e.session = s
                let oldSets = e.sets; let desiredSets = Set(x.sets.map(\.id))
                for l in oldSets where !desiredSets.contains(l.id) { e.sets.removeAll { $0.id == l.id }; c.delete(l) }
                for y in x.sets {
                    let l = oldSets.first { $0.id == y.id } ?? SetLog(position: y.position)
                    if l.modelContext == nil { c.insert(l) }; l.position = y.position; l.kind = y.kind; l.restSeconds = y.restSeconds
                    l.id = y.id; l.sourceSetID = y.sourceSetID; l.prescribedKindRaw = y.prescribedKind.rawValue
                    l.prescribedReps = y.prescribedReps; l.prescribedLoad = y.prescribedLoad
                    l.prescribedIntensity = y.prescribedIntensity; l.intensityScaleRaw = y.intensityScale.rawValue
                    l.intensity = y.intensity; l.notes = y.notes; l.status = y.status; l.completedAt = y.completedAt; l.exercise = e
                    let oldSegments = l.segments; let desiredSegments = Set(y.segments.map(\.id))
                    for p in oldSegments where !desiredSegments.contains(p.id) { l.segments.removeAll { $0.id == p.id }; c.delete(p) }
                    for z in y.segments {
                        let p = oldSegments.first { $0.id == z.id } ?? SetLogSegment(position: z.position)
                        if p.modelContext == nil { c.insert(p) }; p.position = z.position; p.id = z.id
                        p.reps = z.reps; p.loadKg = z.loadKg; p.set = l
                    }
                }
            }
        default: throw SyncFailure.invalidResponse
        }
    }
}

nonisolated enum SnapshotError: LocalizedError {
    case missingExercise(String)
    var errorDescription: String? {
        switch self { case .missingExercise(let name): "O exercício \(name) ainda não foi recebido. Tente sincronizar novamente." }
    }
}
