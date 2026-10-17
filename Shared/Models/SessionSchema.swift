import Foundation
import SwiftData

nonisolated enum SessionStatus: String, Codable { case inProgress, paused, completed, cancelled }
nonisolated enum LoggedSetStatus: String, Codable { case pending, completed, skipped }
nonisolated enum EntityKind: String, Codable, CaseIterable { case program, exercise, workout, session }

enum TrackerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    // Reuse the unchanged V1 entity types, keeping their persistent identities intact.
    static var models: [any PersistentModel.Type] {
        TrackerSchemaV1.models + [WorkoutSession.self, ExerciseLog.self, SetLog.self,
            SetLogSegment.self, SyncRecord.self, PendingMutation.self, SyncConflict.self, SyncCursor.self]
    }

    @Model final class WorkoutSession {
        @Attribute(.unique) var id: UUID
        var sourceTemplateID: UUID?
        var name: String
        var prescription: Data
        var statusRaw: String
        var startedAt: Date
        var endedAt: Date?
        var pausedAt: Date?
        var pausedSeconds: Double
        var timezoneID: String
        var deviceID: String
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        var restStartedAt: Date?
        var restEndsAt: Date?
        var pausedRestSeconds: Double?
        var currentExerciseID: UUID?
        var activityDismissed: Bool
        @Relationship(deleteRule: .cascade, inverse: \ExerciseLog.session)
        var exercises: [ExerciseLog] = []
        var status: SessionStatus {
            get { SessionStatus(rawValue: statusRaw) ?? .inProgress }
            set { statusRaw = newValue.rawValue }
        }
        var orderedExercises: [ExerciseLog] { exercises.sorted { $0.position < $1.position } }
        var isActive: Bool { status == .inProgress || status == .paused }
        var completedSetCount: Int { exercises.reduce(0) { $0 + $1.sets.filter { $0.status == .completed }.count } }
        var totalSetCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
        func elapsed(at now: Date = .now) -> TimeInterval {
            max(0, (endedAt ?? pausedAt ?? now).timeIntervalSince(startedAt) - pausedSeconds)
        }
        init(name: String, prescription: Data, sourceTemplateID: UUID? = nil, deviceID: String) {
            id = UUID(); self.name = name; self.prescription = prescription
            self.sourceTemplateID = sourceTemplateID; self.deviceID = deviceID
            statusRaw = SessionStatus.inProgress.rawValue; startedAt = .now
            pausedSeconds = 0; timezoneID = TimeZone.current.identifier; notes = ""
            createdAt = .now; updatedAt = .now; activityDismissed = false
        }
    }

    @Model final class ExerciseLog {
        @Attribute(.unique) var id: UUID
        var sourceItemID: UUID?
        var exerciseID: UUID?
        var prescribedName: String
        var name: String
        var muscle: String
        var position: Int
        var notes: String
        var session: WorkoutSession?
        @Relationship(deleteRule: .cascade, inverse: \SetLog.exercise)
        var sets: [SetLog] = []
        var orderedSets: [SetLog] { sets.sorted { $0.position < $1.position } }
        func number(for set: SetLog) -> Int? {
            guard set.kind.isNumbered else { return nil }
            return orderedSets.prefix { $0.id != set.id }.filter { $0.kind.isNumbered }.count + 1
        }
        init(name: String, position: Int, exerciseID: UUID? = nil, sourceItemID: UUID? = nil,
             prescribedName: String = "", muscle: String = "") {
            id = UUID(); self.name = name; self.position = position; self.exerciseID = exerciseID
            self.sourceItemID = sourceItemID; self.prescribedName = prescribedName
            self.muscle = muscle; notes = ""
        }
    }

    @Model final class SetLog {
        @Attribute(.unique) var id: UUID
        var sourceSetID: UUID?
        var position: Int
        var kindRaw: String
        var prescribedKindRaw: String
        var prescribedReps: String
        var prescribedLoad: String
        var prescribedIntensity: String
        var intensityScaleRaw: String
        var intensity: String
        var restSeconds: Int
        var notes: String
        var statusRaw: String
        var completedAt: Date?
        var exercise: ExerciseLog?
        @Relationship(deleteRule: .cascade, inverse: \SetLogSegment.set)
        var segments: [SetLogSegment] = []
        var kind: SetKind {
            get { SetKind(rawValue: kindRaw) ?? .working }
            set { kindRaw = newValue.rawValue }
        }
        var status: LoggedSetStatus {
            get { LoggedSetStatus(rawValue: statusRaw) ?? .pending }
            set { statusRaw = newValue.rawValue }
        }
        var orderedSegments: [SetLogSegment] { segments.sorted { $0.position < $1.position } }
        init(position: Int, kind: SetKind = .working, restSeconds: Int = 120) {
            id = UUID(); self.position = position; kindRaw = kind.rawValue
            prescribedKindRaw = kind.rawValue; prescribedReps = ""; prescribedLoad = ""
            prescribedIntensity = ""; intensityScaleRaw = IntensityScale.rir.rawValue
            intensity = ""; self.restSeconds = restSeconds; notes = ""
            statusRaw = LoggedSetStatus.pending.rawValue
        }
    }

    @Model final class SetLogSegment {
        @Attribute(.unique) var id: UUID
        var position: Int
        var reps: Int?
        // Canonical decimal string, validated numerically; nil and explicit "0" differ.
        var loadKg: String?
        var set: SetLog?
        init(position: Int = 0) { id = UUID(); self.position = position }
    }

    @Model final class SyncRecord {
        @Attribute(.unique) var key: String
        var kindRaw: String
        var entityID: UUID
        var serverRevision: Int64
        var localPayload: Data?
        var syncedPayload: Data?
        var isDeleted: Bool
        init(kind: EntityKind, entityID: UUID, payload: Data?) {
            key = "\(kind.rawValue):\(entityID.uuidString.lowercased())"
            kindRaw = kind.rawValue; self.entityID = entityID; serverRevision = 0
            localPayload = payload; isDeleted = payload == nil
        }
    }

    @Model final class PendingMutation {
        @Attribute(.unique) var id: UUID
        var recordKey: String
        var kindRaw: String
        var entityID: UUID
        var baseRevision: Int64
        var payload: Data?
        var hasBeenSent: Bool
        var createdAt: Date
        init(record: SyncRecord) {
            id = UUID(); recordKey = record.key; kindRaw = record.kindRaw
            entityID = record.entityID; baseRevision = record.serverRevision
            payload = record.localPayload; hasBeenSent = false; createdAt = .now
        }
    }

    @Model final class SyncConflict {
        @Attribute(.unique) var recordKey: String
        var kindRaw: String
        var entityID: UUID
        var localPayload: Data?
        var remotePayload: Data?
        var remoteRevision: Int64
        var createdAt: Date
        init(record: SyncRecord, remotePayload: Data?, revision: Int64) {
            recordKey = record.key; kindRaw = record.kindRaw; entityID = record.entityID
            localPayload = record.localPayload; self.remotePayload = remotePayload
            remoteRevision = revision; createdAt = .now
        }
    }

    @Model final class SyncCursor {
        @Attribute(.unique) var key: String
        var revision: Int64
        init() { key = "changes-v1"; revision = 0 }
    }
}

typealias WorkoutSession = TrackerSchemaV2.WorkoutSession
typealias ExerciseLog = TrackerSchemaV2.ExerciseLog
typealias SetLog = TrackerSchemaV2.SetLog
typealias SetLogSegment = TrackerSchemaV2.SetLogSegment
typealias SyncRecord = TrackerSchemaV2.SyncRecord
typealias PendingMutation = TrackerSchemaV2.PendingMutation
typealias SyncConflict = TrackerSchemaV2.SyncConflict
typealias SyncCursor = TrackerSchemaV2.SyncCursor
