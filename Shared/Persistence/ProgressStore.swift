import Foundation
import SwiftData

@MainActor struct BodyStore {
    let store: WorkoutStore
    @discardableResult func saveProfile(height: String, birthDate: String?, notes: String, draftKey: String? = nil) -> Bool {
        do {
            let old = try store.context.fetch(FetchDescriptor<BodyProfile>()).first
            let d = BodyProfileSnapshot(id: BodyProfile.canonicalID, heightCm: try ProgressRules.height(height),
                birthDate: birthDate, notes: notes, createdAt: old?.createdAt ?? .now, updatedAt: .now)
            try ProgressValidation.profile(d)
            return commitProgress(kind: .bodyProfile, id: d.id, data: try SnapshotCodec.encode(d), store: store, draftKey: draftKey)
        } catch { store.operationError = error.localizedDescription; return false }
    }
    @discardableResult func saveRecord(id: UUID, date: Date, timezoneID: String,
        values: [(MetricKind, String)], method: CompositionMethod?, methodNotes: String, notes: String, draftKey: String? = nil) -> Bool {
        do {
            let old = try store.context.fetch(FetchDescriptor<BodyRecord>()).first { $0.id == id }
            if old == nil, try store.context.fetch(FetchDescriptor<SyncRecord>()).contains(where: { $0.kindRaw == "bodyRecord" && $0.entityID == id && $0.isDeleted }) {
                throw SyncFailure.deletedRemotely
            }
            let existing = Dictionary(uniqueKeysWithValues: (old?.values ?? []).map { ($0.kindRaw, $0.id) })
            let entries = try values.enumerated().map { position, pair in
                BodyValueSnapshot(id: existing[pair.0.rawValue] ?? UUID(), kind: pair.0, unit: pair.0.unit,
                    value: try ProgressRules.canonical(pair.1, kind: pair.0), position: position)
            }
            let d = BodyRecordSnapshot(id: id, measuredAt: date, timezoneID: timezoneID, source: "manual",
                method: method, methodNotes: methodNotes, notes: notes, createdAt: old?.createdAt ?? .now,
                updatedAt: .now, values: entries)
            try ProgressValidation.body(d)
            return commitProgress(kind: .bodyRecord, id: id, data: try SnapshotCodec.encode(d), store: store, draftKey: draftKey)
        } catch { store.operationError = error.localizedDescription; return false }
    }
    @discardableResult func delete(_ record: BodyRecord) -> Bool {
        commitProgress(kind: .bodyRecord, id: record.id, data: nil, store: store)
    }
}

@MainActor struct SleepStore {
    let store: WorkoutStore
    @discardableResult func save(id: UUID, start: Date, end: Date, startTimezoneID: String, endTimezoneID: String,
        awakenings: String, quality: SleepQuality?, notes: String, draftKey: String? = nil) -> Bool {
        do {
            let text = awakenings.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = text.isEmpty ? nil : Int(text)
            guard text.isEmpty || (text.range(of: #"^\d+$"#, options: .regularExpression) != nil && count != nil) else {
                throw ProgressFailure.invalidSleep
            }
            let all = try store.context.fetch(FetchDescriptor<SleepRecord>())
            if !all.contains(where: { $0.id == id }), try store.context.fetch(FetchDescriptor<SyncRecord>()).contains(where: { $0.kindRaw == "sleep" && $0.entityID == id && $0.isDeleted }) {
                throw SyncFailure.deletedRemotely
            }
            let day = ProgressRules.day(end, timezoneID: endTimezoneID)
            guard !all.contains(where: { $0.id != id && $0.wakeDate == day }) else { throw ProgressFailure.duplicateNight }
            let old = all.first { $0.id == id }
            let d = SleepSnapshot(id: id, startedAt: start, endedAt: end, startTimezoneID: startTimezoneID,
                endTimezoneID: endTimezoneID, wakeDate: day, awakenings: count, quality: quality, notes: notes,
                source: "manual", createdAt: old?.createdAt ?? .now, updatedAt: .now)
            try ProgressValidation.sleep(d)
            return commitProgress(kind: .sleep, id: id, data: try SnapshotCodec.encode(d), store: store, draftKey: draftKey)
        } catch { store.operationError = error.localizedDescription; return false }
    }
    @discardableResult func delete(_ record: SleepRecord) -> Bool {
        commitProgress(kind: .sleep, id: record.id, data: nil, store: store)
    }
}

@MainActor @discardableResult private func commitProgress(kind: EntityKind, id: UUID, data: Data?, store: WorkoutStore, draftKey: String? = nil) -> Bool {
    let previous: Data?
    do { previous = try ProgressSnapshots.capture(kind: kind, id: id, in: store.context) }
    catch { store.operationError = error.localizedDescription; return false }
    func restore() {
        store.context.rollback()
        // SwiftData can retain edited values in registered model instances after
        // rolling back the backing store. Restore the aggregate's cached graph too.
        if let previous {
            do { try ProgressSnapshots.apply(kind: kind, id: id, payload: previous, in: store.context) }
            catch { store.operationError = "Não foi possível restaurar a edição na tela. Feche e reabra o aplicativo. " + error.localizedDescription }
        }
    }
    do {
        try ProgressSnapshots.apply(kind: kind, id: id, payload: data, in: store.context)
        if let draftKey {
            for draft in try store.context.fetch(FetchDescriptor<EntryDraft>()) where draft.key == draftKey { store.context.delete(draft) }
        }
        guard store.save() else { restore(); return false }
        store.operationError = nil; return true
    } catch {
        store.operationError = error.localizedDescription; restore(); return false
    }
}

@MainActor struct ProgressDraftStore {
    let store: WorkoutStore
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let item = try? store.context.fetch(FetchDescriptor<EntryDraft>()).first(where: { $0.key == key }) else { return nil }
        return try? SnapshotCodec.decode(type, from: item.payload)
    }
    @discardableResult func save<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try SnapshotCodec.encode(value)
            let item = try store.context.fetch(FetchDescriptor<EntryDraft>()).first { $0.key == key }
                ?? EntryDraft(key: key, payload: data)
            if item.modelContext == nil { store.context.insert(item) }
            item.payload = data; item.updatedAt = .now; try store.context.save(); return true
        } catch { store.saveError = "Não foi possível guardar o rascunho. " + error.localizedDescription; return false }
    }
    @discardableResult func remove(key: String) -> Bool {
        do {
            for item in try store.context.fetch(FetchDescriptor<EntryDraft>()) where item.key == key { store.context.delete(item) }
            try store.context.save(); return true
        } catch { store.saveError = error.localizedDescription; return false }
    }
}
