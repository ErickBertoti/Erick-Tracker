import Foundation
import SwiftData

nonisolated struct BodyProfileSnapshot: Codable {
    var id: UUID; var heightCm: String?; var birthDate: String?; var notes: String
    var createdAt: Date; var updatedAt: Date
}
nonisolated struct BodyValueSnapshot: Codable {
    var id: UUID; var kind: MetricKind; var unit: String; var value: String; var position: Int
}
nonisolated struct BodyRecordSnapshot: Codable {
    var id: UUID; var measuredAt: Date; var timezoneID: String; var source: String
    var method: CompositionMethod?; var methodNotes: String; var notes: String
    var createdAt: Date; var updatedAt: Date; var values: [BodyValueSnapshot]
}
nonisolated struct SleepSnapshot: Codable {
    var id: UUID; var startedAt: Date; var endedAt: Date
    var startTimezoneID: String; var endTimezoneID: String; var wakeDate: String
    var awakenings: Int?; var quality: SleepQuality?; var notes: String; var source: String
    var createdAt: Date; var updatedAt: Date
}

nonisolated enum ProgressValidation {
    static func profile(_ p: BodyProfileSnapshot) throws {
        guard p.id == UUID(uuidString: "00000000-0000-0000-0000-000000000003") else { throw ProgressFailure.invalidSnapshot }
        if let h = p.heightCm { guard try ProgressRules.height(h) == h else { throw ProgressFailure.invalidNumber("altura") } }
        if let b = p.birthDate, ProgressRules.civilDate(b) == nil { throw ProgressFailure.invalidDate }
    }
    static func body(_ p: BodyRecordSnapshot) throws {
        guard TimeZone(identifier: p.timezoneID) != nil, p.measuredAt.timeIntervalSince1970.isFinite,
              p.source == "manual" else { throw ProgressFailure.invalidDate }
        guard !p.values.isEmpty else { throw ProgressFailure.emptyRecord }
        guard Set(p.values.map(\.kind)).count == p.values.count,
              Set(p.values.map(\.id)).count == p.values.count else { throw ProgressFailure.invalidSnapshot }
        for value in p.values {
            guard value.unit == value.kind.unit, value.position >= 0,
                  try ProgressRules.canonical(value.value, kind: value.kind) == value.value else { throw ProgressFailure.invalidNumber(value.kind.label) }
        }
        if p.values.contains(where: { $0.kind.isComposition }), p.method == nil { throw ProgressFailure.methodRequired }
    }
    static func sleep(_ p: SleepSnapshot) throws {
        guard p.startedAt.timeIntervalSince1970.isFinite, p.endedAt.timeIntervalSince1970.isFinite,
              p.endedAt > p.startedAt, p.awakenings.map({ $0 >= 0 }) ?? true else { throw ProgressFailure.invalidSleep }
        guard TimeZone(identifier: p.startTimezoneID) != nil, TimeZone(identifier: p.endTimezoneID) != nil,
              p.wakeDate == ProgressRules.day(p.endedAt, timezoneID: p.endTimezoneID), p.source == "manual" else { throw ProgressFailure.invalidDate }
    }
}

@MainActor enum ProgressSnapshots {
    static func profile(_ p: BodyProfile) -> BodyProfileSnapshot {
        .init(id: p.id, heightCm: p.heightCm, birthDate: p.birthDate, notes: p.notes, createdAt: p.createdAt, updatedAt: p.updatedAt)
    }
    static func body(_ p: BodyRecord) -> BodyRecordSnapshot {
        .init(id: p.id, measuredAt: p.measuredAt, timezoneID: p.timezoneID, source: p.source,
            method: p.method, methodNotes: p.methodNotes, notes: p.notes, createdAt: p.createdAt, updatedAt: p.updatedAt,
            values: p.orderedValues.compactMap { v in
                guard let kind = v.kind else { return nil }
                return .init(id: v.id, kind: kind, unit: v.unit, value: v.value, position: v.position)
            })
    }
    static func sleep(_ s: SleepRecord) -> SleepSnapshot {
        .init(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt, startTimezoneID: s.startTimezoneID,
            endTimezoneID: s.endTimezoneID, wakeDate: s.wakeDate, awakenings: s.awakenings, quality: s.quality,
            notes: s.notes, source: s.source, createdAt: s.createdAt, updatedAt: s.updatedAt)
    }
    static func capture(kind: EntityKind, id: UUID, in c: ModelContext) throws -> Data? {
        switch kind {
        case .bodyProfile:
            return try c.fetch(FetchDescriptor<BodyProfile>()).first { $0.id == id }.map { try SnapshotCodec.encode(profile($0)) }
        case .bodyRecord:
            return try c.fetch(FetchDescriptor<BodyRecord>()).first { $0.id == id }.map { try SnapshotCodec.encode(body($0)) }
        case .sleep:
            return try c.fetch(FetchDescriptor<SleepRecord>()).first { $0.id == id }.map { try SnapshotCodec.encode(sleep($0)) }
        default: throw ProgressFailure.invalidSnapshot
        }
    }
    static func all(in c: ModelContext) throws -> [(EntityKind, UUID, Data)] {
        var result: [(EntityKind, UUID, Data)] = []
        for p in try c.fetch(FetchDescriptor<BodyProfile>()) { result.append((.bodyProfile, p.id, try SnapshotCodec.encode(profile(p)))) }
        for p in try c.fetch(FetchDescriptor<BodyRecord>()) { result.append((.bodyRecord, p.id, try SnapshotCodec.encode(body(p)))) }
        for p in try c.fetch(FetchDescriptor<SleepRecord>()) { result.append((.sleep, p.id, try SnapshotCodec.encode(sleep(p)))) }
        return result
    }
    static func apply(kind: EntityKind, id: UUID, payload: Data?, in c: ModelContext) throws {
        guard let payload else {
            switch kind {
            case .bodyRecord:
                if let p = try c.fetch(FetchDescriptor<BodyRecord>()).first(where: { $0.id == id }) {
                    // Detach and delete children explicitly so a failed save can
                    // restore the graph without invalidated cascade backing data.
                    let values = p.values
                    p.values.removeAll()
                    for value in values { c.delete(value) }
                    c.delete(p)
                }
            case .sleep: if let p = try c.fetch(FetchDescriptor<SleepRecord>()).first(where: { $0.id == id }) { c.delete(p) }
            default: throw ProgressFailure.invalidSnapshot // A profile is cleared, never tombstoned.
            }
            return
        }
        switch kind {
        case .bodyProfile:
            let d = try SnapshotCodec.decode(BodyProfileSnapshot.self, from: payload); try ProgressValidation.profile(d)
            guard d.id == id else { throw ProgressFailure.invalidSnapshot }
            let p = try c.fetch(FetchDescriptor<BodyProfile>()).first { $0.id == id } ?? BodyProfile()
            if p.modelContext == nil { c.insert(p) }
            p.heightCm = d.heightCm; p.birthDate = d.birthDate; p.notes = d.notes; p.createdAt = d.createdAt; p.updatedAt = d.updatedAt
        case .bodyRecord:
            let d = try SnapshotCodec.decode(BodyRecordSnapshot.self, from: payload); try ProgressValidation.body(d)
            guard d.id == id else { throw ProgressFailure.invalidSnapshot }
            let p = try c.fetch(FetchDescriptor<BodyRecord>()).first { $0.id == id } ?? BodyRecord()
            if p.modelContext == nil { c.insert(p) }; p.id = id
            p.measuredAt = d.measuredAt; p.timezoneID = d.timezoneID; p.source = d.source
            p.methodRaw = d.method?.rawValue; p.methodNotes = d.methodNotes; p.notes = d.notes
            p.createdAt = d.createdAt; p.updatedAt = d.updatedAt
            let old = p.values; let desired = Set(d.values.map(\.id))
            for v in old where !desired.contains(v.id) { p.values.removeAll { $0.id == v.id }; c.delete(v) }
            let allValues = try c.fetch(FetchDescriptor<BodyValue>())
            for x in d.values {
                if let other = allValues.first(where: { $0.id == x.id }), other.record?.id != id { throw ProgressFailure.invalidSnapshot }
                let v = old.first { $0.id == x.id } ?? BodyValue(kind: x.kind, value: x.value, position: x.position)
                if v.modelContext == nil { c.insert(v) }
                v.id = x.id; v.kindRaw = x.kind.rawValue; v.unit = x.unit; v.value = x.value; v.position = x.position; v.record = p
            }
        case .sleep:
            let d = try SnapshotCodec.decode(SleepSnapshot.self, from: payload); try ProgressValidation.sleep(d)
            guard d.id == id else { throw ProgressFailure.invalidSnapshot }
            let p = try c.fetch(FetchDescriptor<SleepRecord>()).first { $0.id == id }
                ?? SleepRecord(start: d.startedAt, end: d.endedAt, timezoneID: d.endTimezoneID)
            if p.modelContext == nil { c.insert(p) }; p.id = id
            p.startedAt = d.startedAt; p.endedAt = d.endedAt; p.startTimezoneID = d.startTimezoneID
            p.endTimezoneID = d.endTimezoneID; p.wakeDate = d.wakeDate
            p.awakenings = d.awakenings; p.qualityRaw = d.quality?.rawValue; p.notes = d.notes; p.source = d.source
            p.createdAt = d.createdAt; p.updatedAt = d.updatedAt
        default: throw ProgressFailure.invalidSnapshot
        }
    }
}
