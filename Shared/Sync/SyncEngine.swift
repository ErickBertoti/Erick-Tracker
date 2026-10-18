import Foundation
import Observation
import SwiftData

nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([JSONValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
}
nonisolated struct MutationRequest: Codable, Sendable {
    var protocolVersion = 2
    var mutationID: UUID; var kind: EntityKind; var entityID: UUID
    var baseRevision: Int64; var payload: JSONValue?; var deleted: Bool
}
nonisolated struct MutationReply: Codable, Sendable {
    var status: String; var revision: Int64; var payload: JSONValue?; var deleted: Bool
    var competingEntityID: UUID?
    var competingRevision: Int64?
    var competingPayload: JSONValue?
}
nonisolated struct RemoteChange: Codable, Sendable {
    var revision: Int64; var kind: EntityKind; var entityID: UUID; var payload: JSONValue?; var deleted: Bool
}
@MainActor protocol CloudTransport {
    func apply(_ request: MutationRequest) async throws -> MutationReply
    func pull(after revision: Int64, limit: Int) async throws -> [RemoteChange]
}

@MainActor @Observable final class SyncEngine {
    let store: WorkoutStore
    private let transport: any CloudTransport
    var isSyncing = false
    var error: String?
    var lastSyncAt: Date?
    var enabled = true
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    init(store: WorkoutStore, transport: any CloudTransport) { self.store = store; self.transport = transport }
    var context: ModelContext { store.context }
    var pendingCount: Int { (try? context.fetchCount(FetchDescriptor<PendingMutation>())) ?? 0 }
    var conflictCount: Int { (try? context.fetchCount(FetchDescriptor<SyncConflict>())) ?? 0 }
    var status: String {
        if isSyncing { return "Sincronizando…" }
        if error != nil { return "Sincronização pendente" }
        if conflictCount > 0 { return "Conflitos para resolver" }
        if pendingCount > 0 { return "\(pendingCount) alteração(ões) pendente(s)" }
        return lastSyncAt == nil ? "Salvo localmente" : "Sincronizado"
    }
    func schedule() {
        guard enabled, !isSyncing else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }; await self?.sync()
        }
    }
    func stop() { enabled = false; scheduled?.cancel() }
    func sync() async {
        guard enabled, !isSyncing else { return }
        var runAgain = false
        isSyncing = true
        defer { isSyncing = false; if runAgain && enabled { schedule() } }
        do {
            guard store.save() else { error = store.saveError; return }
            var blocked = Set(try context.fetch(FetchDescriptor<SyncConflict>()).map(\.recordKey))
            // Replay uncertain requests before pulling. A lost response followed by a
            // new local edit must acknowledge the old operation, not conflict with it.
            for mutation in try queued().filter(\.hasBeenSent) {
                guard enabled, !Task.isCancelled else { return }
                if !blocked.contains(mutation.recordKey) { try await send(mutation, blocked: &blocked) }
            }
            try await receiveChanges()
            guard store.save() else { error = store.saveError; return }
            blocked.formUnion(try context.fetch(FetchDescriptor<SyncConflict>()).map(\.recordKey))
            // Capture a bounded batch. New local edits stay in the next immutable request.
            let pending = try queued().filter { !$0.hasBeenSent && !blocked.contains($0.recordKey) }
                .sorted { a, b in
                    let ap = Self.dependencyOrder(a), bp = Self.dependencyOrder(b)
                    return ap == bp ? a.createdAt < b.createdAt : ap < bp
                }
            for mutation in pending.prefix(500) {
                guard enabled, !Task.isCancelled else { return }
                if blocked.contains(mutation.recordKey) { continue }
                try await send(mutation, blocked: &blocked)
            }
            try await receiveChanges()
            error = nil; lastSyncAt = .now
            let conflicts = Set(try context.fetch(FetchDescriptor<SyncConflict>()).map(\.recordKey))
            runAgain = try queued().contains { !conflicts.contains($0.recordKey) }
        } catch {
            // All confirmed local edits were saved before network I/O. Roll back only an
            // incomplete receive transaction so a failed page can be replayed safely.
            context.rollback(); self.error = error.localizedDescription
        }
    }
    private func queued() throws -> [PendingMutation] {
        try context.fetch(FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)]))
    }
    private static func dependencyOrder(_ mutation: PendingMutation) -> Int {
        switch EntityKind(rawValue: mutation.kindRaw) {
        case .program: mutation.payload == nil ? 4 : 0
        case .exercise: mutation.payload == nil ? 5 : 1
        case .workout: 2
        case .session: 3
        case .bodyProfile: 0
        case .bodyRecord, .sleep: mutation.payload == nil ? 5 : 3
        case .unknown, nil: 6
        }
    }
    private func send(_ mutation: PendingMutation, blocked: inout Set<String>) async throws {
        guard let record = try record(for: mutation.recordKey),
              let kind = EntityKind(rawValue: mutation.kindRaw) else { throw SyncFailure.invalidResponse }
        mutation.hasBeenSent = true; try context.save()
        let request = MutationRequest(protocolVersion: mutation.protocolVersion, mutationID: mutation.id, kind: kind, entityID: mutation.entityID,
            baseRevision: mutation.baseRevision,
            payload: try mutation.payload.map { try SnapshotCodec.decode(JSONValue.self, from: $0) },
            deleted: mutation.payload == nil)
        let reply = try await transport.apply(request)
        guard enabled, !Task.isCancelled else { return }
        let remote = try canonical(reply.payload, kind: kind)
        if reply.status == "duplicateNight" {
            guard kind == .sleep, let id = reply.competingEntityID, let revision = reply.competingRevision,
                  let other = try canonical(reply.competingPayload, kind: .sleep) else { throw SyncFailure.invalidResponse }
            let conflict = try conflict(record, payload: remote, revision: reply.revision)
            conflict.reasonRaw = "duplicateNight"; conflict.competingID = id
            conflict.competingPayload = other; conflict.competingRevision = revision
            try receiveCompetingNight(id: id, payload: other, revision: revision)
            blocked.insert(record.key)
        } else if reply.status == "conflict" {
            blocked.insert(record.key)
            try conflict(record, payload: remote, revision: reply.revision)
        } else {
            guard reply.status == "applied" else { throw SyncFailure.invalidResponse }
            if record.localPayload == mutation.payload, remote != mutation.payload {
                try Snapshots.apply(kind: kind, id: request.entityID, payload: remote, in: context)
                record.localPayload = remote; record.isDeleted = remote == nil
            }
            record.serverRevision = reply.revision; record.syncedPayload = remote
            context.delete(mutation)
            for next in try queued() where next.recordKey == record.key && !next.hasBeenSent {
                next.baseRevision = reply.revision
            }
        }
        try context.save()
    }
    private func receiveChanges() async throws {
    let cursor = try context.fetch(FetchDescriptor<SyncCursor>()).first { $0.key == "changes-v2" } ?? SyncCursor()
    cursor.key = "changes-v2"
    if cursor.modelContext == nil { context.insert(cursor) }
    while enabled {
        let changes = try await transport.pull(after: cursor.revision, limit: 100)
        guard enabled, !Task.isCancelled else { return }
        for change in changes {
            guard change.kind != .unknown else { throw SyncFailure.invalidResponse }
            let key = "\(change.kind.rawValue):\(change.entityID.uuidString.lowercased())"
            let payload = try canonical(change.payload, kind: change.kind)
            let r = try record(for: key) ?? SyncRecord(kind: change.kind, entityID: change.entityID, payload: nil)
            if r.modelContext == nil { context.insert(r) }
            if change.revision > r.serverRevision {
                let dirty = try context.fetch(FetchDescriptor<PendingMutation>()).contains { $0.recordKey == key }
                let referencedLocally = try change.kind == .exercise && payload == nil &&
                    ((try context.fetch(FetchDescriptor<Exercise>()).first { $0.id == change.entityID })?.items.isEmpty == false)
                if dirty && change.kind == .workout,
                   try rebaseProgramRemoval(r, remote: payload, revision: change.revision) {
                    // Program deletion only detaches its templates. Preserve local
                    // template edits while acknowledging that structural change.
                } else if (dirty && r.localPayload != payload) || referencedLocally {
                    try conflict(r, payload: payload, revision: change.revision)
                } else if change.kind == .workout, let payload,
                          try protectMissingExercises(in: payload) {
                    // A new remote template may reference an exercise deleted
                    // offline here. Preserve both decisions for explicit resolution.
                    try conflict(r, payload: payload, revision: change.revision)
                } else {
                    try Snapshots.apply(kind: change.kind, id: change.entityID, payload: payload, in: context)
                    r.localPayload = payload; r.syncedPayload = payload
                    r.serverRevision = change.revision; r.isDeleted = payload == nil
                    if dirty {
                        for p in try context.fetch(FetchDescriptor<PendingMutation>()) where p.recordKey == key { context.delete(p) }
                    }
                }
            }
            cursor.revision = change.revision
        }
        try context.save()
        if changes.count < 100 { break }
    }
    }
    private func protectMissingExercises(in payload: Data) throws -> Bool {
        let workout = try SnapshotCodec.decode(WorkoutSnapshot.self, from: payload)
        let present = Set(try context.fetch(FetchDescriptor<Exercise>()).map(\.id))
        let missing = Set(workout.items.compactMap(\.exerciseID)).subtracting(present)
        for id in missing {
            let key = "exercise:\(id.uuidString.lowercased())"
            if let r = try record(for: key), let baseline = r.syncedPayload {
                try conflict(r, payload: baseline, revision: r.serverRevision)
            }
        }
        return !missing.isEmpty
    }
    private func rebaseProgramRemoval(_ record: SyncRecord, remote: Data?, revision: Int64) throws -> Bool {
        guard let baseline = record.syncedPayload, let remote, let local = record.localPayload else { return false }
        var previous = try SnapshotCodec.decode(WorkoutSnapshot.self, from: baseline)
        let removedProgram = previous.programID
        guard removedProgram != nil else { return false }
        previous.programID = nil
        guard try SnapshotCodec.encode(previous) == remote else { return false }
        var current = try SnapshotCodec.decode(WorkoutSnapshot.self, from: local)
        if current.programID == removedProgram { current.programID = nil }
        let updated = try SnapshotCodec.encode(current)
        try Snapshots.apply(kind: .workout, id: record.entityID, payload: updated, in: context)
        record.localPayload = updated; record.syncedPayload = remote; record.serverRevision = revision
        for mutation in try queued() where mutation.recordKey == record.key && !mutation.hasBeenSent {
            mutation.baseRevision = revision; mutation.payload = updated
            if updated == remote { context.delete(mutation) }
        }
        return true
    }
    private func record(for key: String) throws -> SyncRecord? {
        try context.fetch(FetchDescriptor<SyncRecord>()).first { $0.key == key }
    }
    @discardableResult private func conflict(_ record: SyncRecord, payload: Data?, revision: Int64) throws -> SyncConflict {
        if let existing = try context.fetch(FetchDescriptor<SyncConflict>()).first(where: { $0.recordKey == record.key }) {
            existing.localPayload = record.localPayload; existing.remotePayload = payload; existing.remoteRevision = revision
            return existing
        } else {
            let item = SyncConflict(record: record, remotePayload: payload, revision: revision)
            context.insert(item); return item
        }
    }
    private func canonical(_ value: JSONValue?, kind: EntityKind) throws -> Data? {
        guard let value, value != .null else { return nil }
        let bytes = try SnapshotCodec.encode(value)
        switch kind {
        case .program: return try SnapshotCodec.encode(SnapshotCodec.decode(ProgramSnapshot.self, from: bytes))
        case .exercise: return try SnapshotCodec.encode(SnapshotCodec.decode(ExerciseSnapshot.self, from: bytes))
        case .workout: return try SnapshotCodec.encode(SnapshotCodec.decode(WorkoutSnapshot.self, from: bytes))
        case .session: return try SnapshotCodec.encode(SnapshotCodec.decode(SessionSnapshot.self, from: bytes))
        case .bodyProfile:
            let p = try SnapshotCodec.decode(BodyProfileSnapshot.self, from: bytes); try ProgressValidation.profile(p)
            return try SnapshotCodec.encode(p)
        case .bodyRecord:
            let p = try SnapshotCodec.decode(BodyRecordSnapshot.self, from: bytes); try ProgressValidation.body(p)
            return try SnapshotCodec.encode(p)
        case .sleep:
            let p = try SnapshotCodec.decode(SleepSnapshot.self, from: bytes); try ProgressValidation.sleep(p)
            return try SnapshotCodec.encode(p)
        case .unknown: throw SyncFailure.invalidResponse
        }
    }
    enum Resolution { case local, remote, both, archiveExercise }
    func resolve(_ conflict: SyncConflict, choosing choice: Resolution) {
        do {
            guard let kind = EntityKind(rawValue: conflict.kindRaw), let r = try record(for: conflict.recordKey) else { return }
            if conflict.reasonRaw == "duplicateNight" { try resolveDuplicateNight(conflict, record: r, choice: choice); return }
            if choice == .remote, kind == .exercise, conflict.remotePayload == nil,
               let exercise = try context.fetch(FetchDescriptor<Exercise>()).first(where: { $0.id == r.entityID }),
               !exercise.items.isEmpty { throw SyncFailure.exerciseReferenced }
            let local = r.localPayload
            var copy: WorkoutSnapshot?
            var bodyCopy: BodyRecordSnapshot?
            if kind == .bodyRecord, let local,
               choice == .both || (choice == .local && conflict.remotePayload == nil) {
                var d = try SnapshotCodec.decode(BodyRecordSnapshot.self, from: local)
                d.id = UUID(); d.createdAt = .now; d.updatedAt = .now
                for i in d.values.indices { d.values[i].id = UUID() }; bodyCopy = d
            } else if choice == .both || (choice == .local && conflict.remotePayload == nil && kind == .workout) {
                guard kind == .workout, let local else { return }
                var d = try SnapshotCodec.decode(WorkoutSnapshot.self, from: local)
                d.id = UUID(); d.name += " (cópia local)"; d.createdAt = .now; d.updatedAt = .now
                for i in d.items.indices {
                    d.items[i].id = UUID()
                    for j in d.items[i].sets.indices { d.items[i].sets[j].id = UUID() }
                }; copy = d
            } else if choice == .local && conflict.remotePayload == nil && local != nil {
                throw SyncFailure.deletedRemotely
            }
            for p in try context.fetch(FetchDescriptor<PendingMutation>()) where p.recordKey == r.key { context.delete(p) }
            r.serverRevision = conflict.remoteRevision; r.syncedPayload = conflict.remotePayload
            if choice == .remote || copy != nil || bodyCopy != nil {
                try Snapshots.apply(kind: kind, id: r.entityID, payload: conflict.remotePayload, in: context)
                r.localPayload = conflict.remotePayload; r.isDeleted = r.localPayload == nil
            } else {
                if choice == .archiveExercise, let data = conflict.remotePayload {
                    var e = try SnapshotCodec.decode(ExerciseSnapshot.self, from: data)
                    e.isArchived = true; e.updatedAt = .now
                    r.localPayload = try SnapshotCodec.encode(e); r.isDeleted = false
                    try Snapshots.apply(kind: .exercise, id: r.entityID, payload: r.localPayload, in: context)
                }
                context.insert(PendingMutation(record: r))
            }
            if let copy { try Snapshots.apply(kind: .workout, id: copy.id, payload: SnapshotCodec.encode(copy), in: context) }
            if let bodyCopy { try Snapshots.apply(kind: .bodyRecord, id: bodyCopy.id, payload: SnapshotCodec.encode(bodyCopy), in: context) }
            context.delete(conflict)
            guard store.save() else { throw SyncFailure.saveFailed }
            schedule()
        } catch { context.rollback(); store.operationError = error.localizedDescription }
    }

    private func receiveCompetingNight(id: UUID, payload: Data, revision: Int64) throws {
        let key = "sleep:\(id.uuidString.lowercased())"
        let r = try record(for: key) ?? SyncRecord(kind: .sleep, entityID: id, payload: nil)
        if r.modelContext == nil { context.insert(r) }
        guard revision > r.serverRevision else { return }
        let dirty = try queued().contains { $0.recordKey == key }
        if dirty && r.localPayload != payload { try conflict(r, payload: payload, revision: revision); return }
        try Snapshots.apply(kind: .sleep, id: id, payload: payload, in: context)
        r.localPayload = payload; r.syncedPayload = payload; r.serverRevision = revision; r.isDeleted = false
    }

    private func resolveDuplicateNight(_ conflict: SyncConflict, record r: SyncRecord, choice: Resolution) throws {
        guard let otherID = conflict.competingID, let otherData = conflict.competingPayload,
              let otherRevision = conflict.competingRevision else { throw SyncFailure.invalidResponse }
        let other = try SnapshotCodec.decode(SleepSnapshot.self, from: otherData)
        guard choice == .local || choice == .remote else { return }
        let local = r.localPayload
        for p in try queued() where p.recordKey == r.key { context.delete(p) }
        r.serverRevision = conflict.remoteRevision; r.syncedPayload = conflict.remotePayload
        if choice == .remote {
            try Snapshots.apply(kind: .sleep, id: r.entityID, payload: conflict.remotePayload, in: context)
            r.localPayload = conflict.remotePayload; r.isDeleted = r.localPayload == nil
        } else if let local {
            var d = try SnapshotCodec.decode(SleepSnapshot.self, from: local)
            if d.wakeDate != other.wakeDate {
                context.insert(PendingMutation(record: r)) // User corrected the date in Progresso.
            } else {
                let key = "sleep:\(otherID.uuidString.lowercased())"
                let competing = try record(for: key) ?? SyncRecord(kind: .sleep, entityID: otherID, payload: otherData)
                if competing.modelContext == nil { context.insert(competing) }
                guard !(try queued().contains { $0.recordKey == key && $0.hasBeenSent }),
                      !(try context.fetch(FetchDescriptor<SyncConflict>()).contains { $0.recordKey == key }) else {
                    throw ProgressFailure.pendingConflict
                }
                for p in try queued() where p.recordKey == key { context.delete(p) }
                d.id = otherID; d.createdAt = other.createdAt; d.updatedAt = .now
                let data = try SnapshotCodec.encode(d)
                try Snapshots.apply(kind: .sleep, id: otherID, payload: data, in: context)
                competing.serverRevision = otherRevision; competing.syncedPayload = otherData
                competing.localPayload = data; competing.isDeleted = false
                context.insert(PendingMutation(record: competing))
                try Snapshots.apply(kind: .sleep, id: r.entityID, payload: nil, in: context)
                r.localPayload = nil; r.isDeleted = true
                if r.serverRevision > 0 { context.insert(PendingMutation(record: r)) }
            }
        } else {
            r.localPayload = nil; r.isDeleted = true
            if r.serverRevision > 0 { context.insert(PendingMutation(record: r)) }
        }
        context.delete(conflict)
        guard store.save() else { throw SyncFailure.saveFailed }
        schedule()
    }
}
nonisolated enum SyncFailure: LocalizedError {
    case invalidResponse, deletedRemotely, exerciseReferenced, saveFailed
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "O servidor respondeu em um formato incompatível. Atualize o aplicativo e tente novamente."
        case .deletedRemotely: "Este cadastro foi excluído na nuvem. Use a versão da nuvem e crie um novo cadastro para preservar a exclusão."
        case .exerciseReferenced: "Este exercício ainda está em modelos locais. Resolva primeiro os conflitos desses treinos ou substitua o exercício antes de aceitar a exclusão."
        case .saveFailed: "Não foi possível salvar a resolução. As versões continuam preservadas; tente novamente."
        }
    }
}
