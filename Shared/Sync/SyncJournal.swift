import Foundation
import SwiftData

@MainActor enum SyncJournal {
    static func capture(in context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<SyncRecord>())
        var byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        let mutations = try context.fetch(FetchDescriptor<PendingMutation>())
        let conflicts = try context.fetch(FetchDescriptor<SyncConflict>())
        var seen = Set<String>()
        for (kind, id, payload) in try Snapshots.all(in: context) {
            let key = "\(kind.rawValue):\(id.uuidString.lowercased())"; seen.insert(key)
            if let record = byKey[key] {
                guard record.localPayload != payload || record.isDeleted else { continue }
                record.localPayload = payload; record.isDeleted = false
                enqueue(record, existing: mutations, in: context)
            } else {
                let record = SyncRecord(kind: kind, entityID: id, payload: payload)
                context.insert(record); byKey[key] = record
                context.insert(PendingMutation(record: record))
            }
        }
        for record in records where !seen.contains(record.key) && !record.isDeleted {
            record.localPayload = nil; record.isDeleted = true
            enqueue(record, existing: mutations, in: context)
        }
        for conflict in conflicts {
            conflict.localPayload = byKey[conflict.recordKey]?.localPayload
        }
    }
    static func enqueue(_ record: SyncRecord, existing: [PendingMutation], in context: ModelContext) {
        // A request is immutable as soon as it may have reached the server.
        if let pending = existing.last(where: { $0.recordKey == record.key && !$0.hasBeenSent }) {
            pending.payload = record.localPayload
        } else { context.insert(PendingMutation(record: record)) }
    }
}
