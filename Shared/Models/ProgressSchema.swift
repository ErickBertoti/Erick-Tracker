import Foundation
import SwiftData

nonisolated enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case weight, bodyFatPercent, fatMass, skeletalMuscleMass, muscleMass, musclePercent, leanMass
    case waist, abdomen, chest, hip, arm, forearm, thigh, calf, neck
    var id: String { rawValue }
    var label: String {
        switch self {
        case .weight: "Peso"
        case .bodyFatPercent: "Gordura corporal"
        case .fatMass: "Massa de gordura"
        case .skeletalMuscleMass: "Massa muscular esquelética"
        case .muscleMass: "Massa muscular"
        case .musclePercent: "Massa muscular percentual"
        case .leanMass: "Massa magra"
        case .waist: "Cintura"
        case .abdomen: "Abdômen"
        case .chest: "Peitoral"
        case .hip: "Quadril"
        case .arm: "Braço"
        case .forearm: "Antebraço"
        case .thigh: "Coxa"
        case .calf: "Panturrilha"
        case .neck: "Pescoço"
        }
    }
    var isComposition: Bool { [.bodyFatPercent, .fatMass, .skeletalMuscleMass, .muscleMass, .musclePercent, .leanMass].contains(self) }
    var isMeasurement: Bool { !isComposition && self != .weight }
    var unit: String { isMeasurement ? "cm" : ([.bodyFatPercent, .musclePercent].contains(self) ? "%" : "kg") }
    var requiresPositive: Bool { self == .weight || isMeasurement }
}

nonisolated enum CompositionMethod: String, Codable, CaseIterable, Identifiable {
    case bioimpedance, dexa, skinfold, other, unspecified
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bioimpedance: "Bioimpedância"
        case .dexa: "DEXA"
        case .skinfold: "Dobras cutâneas"
        case .other: "Outro"
        case .unspecified: "Não informado"
        }
    }
}

nonisolated enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, fair, good, excellent
    var id: String { rawValue }
    var label: String {
        switch self { case .poor: "Ruim"; case .fair: "Regular"; case .good: "Boa"; case .excellent: "Ótima" }
    }
}

enum TrackerSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TrackerSchemaV1.models + [TrackerSchemaV2.WorkoutSession.self, TrackerSchemaV2.ExerciseLog.self,
            TrackerSchemaV2.SetLog.self, TrackerSchemaV2.SetLogSegment.self, TrackerSchemaV2.SyncRecord.self,
            TrackerSchemaV2.SyncCursor.self, PendingMutation.self, SyncConflict.self,
            BodyProfile.self, BodyRecord.self, BodyValue.self, SleepRecord.self, EntryDraft.self]
    }

    @Model final class BodyProfile {
        @Attribute(.unique) var id: UUID
        var heightCm: String?
        var birthDate: String?
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        static var canonicalID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000003")! }
        init() { id = Self.canonicalID; notes = ""; createdAt = .now; updatedAt = .now }
    }

    @Model final class BodyRecord {
        @Attribute(.unique) var id: UUID
        var measuredAt: Date
        var timezoneID: String
        var source: String
        var methodRaw: String?
        var methodNotes: String
        var notes: String
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \BodyValue.record)
        var values: [BodyValue] = []
        var method: CompositionMethod? { methodRaw.flatMap(CompositionMethod.init(rawValue:)) }
        var orderedValues: [BodyValue] {
            values.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        }
        init(measuredAt: Date = .now, timezoneID: String = TimeZone.current.identifier) {
            id = UUID(); self.measuredAt = measuredAt; self.timezoneID = timezoneID
            source = "manual"; methodNotes = ""; notes = ""; createdAt = .now; updatedAt = .now
        }
    }

    @Model final class BodyValue {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var unit: String
        var value: String
        var position: Int
        var record: BodyRecord?
        var kind: MetricKind? { MetricKind(rawValue: kindRaw) }
        init(kind: MetricKind, value: String, position: Int) {
            id = UUID(); kindRaw = kind.rawValue; unit = kind.unit; self.value = value; self.position = position
        }
    }

    @Model final class SleepRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var endedAt: Date
        var startTimezoneID: String
        var endTimezoneID: String
        var wakeDate: String
        var awakenings: Int?
        var qualityRaw: String?
        var notes: String
        var source: String
        var createdAt: Date
        var updatedAt: Date
        var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
        var quality: SleepQuality? { qualityRaw.flatMap(SleepQuality.init(rawValue:)) }
        init(start: Date, end: Date, timezoneID: String = TimeZone.current.identifier) {
            id = UUID(); startedAt = start; endedAt = end
            startTimezoneID = timezoneID; endTimezoneID = timezoneID
            wakeDate = ProgressRules.day(end, timezoneID: timezoneID)
            notes = ""; source = "manual"; createdAt = .now; updatedAt = .now
        }
    }

    // These two V3 entities retain their V2 persistent names and add defaults.
    // The frozen V2 definitions remain available to migrate existing stores.
    @Model final class PendingMutation {
        @Attribute(.unique) var id: UUID
        var recordKey: String
        var kindRaw: String
        var entityID: UUID
        var baseRevision: Int64
        var payload: Data?
        var hasBeenSent: Bool
        var createdAt: Date
        var protocolVersion: Int = 1
        init(record: SyncRecord) {
            id = UUID(); recordKey = record.key; kindRaw = record.kindRaw; entityID = record.entityID
            baseRevision = record.serverRevision; payload = record.localPayload
            hasBeenSent = false; createdAt = .now; protocolVersion = 2
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
        var reasonRaw: String = "revision"
        var competingID: UUID?
        var competingPayload: Data?
        var competingRevision: Int64?
        init(record: SyncRecord, remotePayload: Data?, revision: Int64) {
            recordKey = record.key; kindRaw = record.kindRaw; entityID = record.entityID
            localPayload = record.localPayload; self.remotePayload = remotePayload
            remoteRevision = revision; createdAt = .now
        }
    }

    @Model final class EntryDraft {
        @Attribute(.unique) var key: String
        var payload: Data
        var updatedAt: Date
        init(key: String, payload: Data) { self.key = key; self.payload = payload; updatedAt = .now }
    }
}

typealias BodyProfile = TrackerSchemaV3.BodyProfile
typealias BodyRecord = TrackerSchemaV3.BodyRecord
typealias BodyValue = TrackerSchemaV3.BodyValue
typealias SleepRecord = TrackerSchemaV3.SleepRecord
typealias PendingMutation = TrackerSchemaV3.PendingMutation
typealias SyncConflict = TrackerSchemaV3.SyncConflict
typealias EntryDraft = TrackerSchemaV3.EntryDraft
