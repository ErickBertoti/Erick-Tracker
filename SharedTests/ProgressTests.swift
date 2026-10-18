import Foundation
import SwiftData
import Testing
#if os(macOS)
@testable import Erick_Tracker
#else
@testable import Erick_Tracker_iOS
#endif

@MainActor @Suite("Fase 3: corpo, sono e migração", .serialized)
struct ProgressTests {
    private func store(url: URL? = nil) throws -> WorkoutStore {
        let c = try PersistenceController.makeContainer(inMemory: url == nil, url: url)
        return WorkoutStore(context: c.mainContext)
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func body(_ s: WorkoutStore, id: UUID = UUID(), value: String = "80,5") throws -> BodyRecord {
        #expect(BodyStore(store: s).saveRecord(id: id, date: date("2026-10-17T10:00:00Z"), timezoneID: "America/Sao_Paulo",
            values: [(.weight, value)], method: nil, methodNotes: "", notes: ""))
        return try #require(s.context.fetch(FetchDescriptor<BodyRecord>()).first { $0.id == id })
    }
    @Test("V2 migra sem reescrever operação enviada, conflitos, cursor e sessão")
    func migrationV2() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "v2.store")
        var pendingID = UUID(), sessionID = UUID(); let payload = Data("{\"fixture\":true}".utf8)
        do {
            let schema = Schema(versionedSchema: TrackerSchemaV2.self)
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration("ErickTracker", schema: schema, url: url, cloudKitDatabase: .none)])
            let c = old.mainContext
            let record = TrackerSchemaV2.SyncRecord(kind: .program, entityID: UUID(), payload: payload)
            record.serverRevision = 17; record.syncedPayload = Data("{}".utf8); c.insert(record)
            let pending = TrackerSchemaV2.PendingMutation(record: record); pending.hasBeenSent = true
            pendingID = pending.id; c.insert(pending)
            c.insert(TrackerSchemaV2.SyncConflict(record: record, remotePayload: payload, revision: 18))
            let cursor = TrackerSchemaV2.SyncCursor(); cursor.revision = 19; c.insert(cursor)
            let session = TrackerSchemaV2.WorkoutSession(name: "Em andamento", prescription: payload, deviceID: "fixture")
            session.restEndsAt = Date(timeIntervalSince1970: 100); sessionID = session.id; c.insert(session)
            try c.save()
        }
        let current = try store(url: url)
        let pending = try #require(current.context.fetch(FetchDescriptor<PendingMutation>()).first { $0.id == pendingID })
        #expect(pending.protocolVersion == 1 && pending.hasBeenSent && pending.baseRevision == 17 && pending.payload == payload)
        let conflict = try #require(current.context.fetch(FetchDescriptor<SyncConflict>()).first)
        #expect(conflict.reasonRaw == "revision" && conflict.remoteRevision == 18 && conflict.remotePayload == payload)
        #expect(try current.context.fetch(FetchDescriptor<SyncCursor>()).first?.revision == 19)
        let session = try #require(current.context.fetch(FetchDescriptor<WorkoutSession>()).first)
        #expect(session.id == sessionID && session.isActive && session.prescription == payload && session.restEndsAt != nil)
        #expect(try current.context.fetchCount(FetchDescriptor<BodyRecord>()) == 0)
    }
    @Test("Decimais, unidades e métricas distintas não se misturam")
    func values() throws {
        #expect(try ProgressRules.canonical("80,50", kind: .weight) == "80.5")
        #expect(try ProgressRules.canonical("0", kind: .bodyFatPercent) == "0")
        for value in ["", "NaN", "1e2", "-2", "10 + 5", "1.000,5", "0"] {
            #expect(throws: (any Error).self) { try ProgressRules.canonical(value, kind: .weight) }
        }
        #expect(throws: (any Error).self) { try ProgressRules.canonical("101", kind: .musclePercent) }
        let s = try store(); let id = UUID()
        #expect(BodyStore(store: s).saveRecord(id: id, date: .now, timezoneID: "GMT",
            values: [(.skeletalMuscleMass,"31,2"),(.muscleMass,"40"),(.leanMass,"56"),(.fatMass,"14"),(.musclePercent,"50")],
            method: .bioimpedance, methodNotes: "Dispositivo fictício", notes: ""))
        let r = try #require(s.context.fetch(FetchDescriptor<BodyRecord>()).first)
        #expect(r.values.count == 5 && r.method == .bioimpedance)
        #expect(r.values.first { $0.kind == .skeletalMuscleMass }?.value == "31.2")
        #expect(r.values.first { $0.kind == .musclePercent }?.unit == "%")
        #expect(!BodyStore(store: s).saveRecord(id: UUID(), date: .now, timezoneID: "GMT",
            values: [(.leanMass,"50")], method: nil, methodNotes: "", notes: ""))
        #expect(try s.context.fetchCount(FetchDescriptor<BodyRecord>()) == 1)
    }
    @Test("Perfil vazio é opcional, e limpar preserva sua identidade")
    func profile() throws {
        let s = try store(); let service = BodyStore(store: s)
        #expect(try s.context.fetchCount(FetchDescriptor<BodyProfile>()) == 0)
        #expect(service.saveProfile(height: "178,5", birthDate: "1990-02-28", notes: "Fictício"))
        #expect(!service.saveProfile(height: "178", birthDate: "2026-02-30", notes: ""))
        #expect(service.saveProfile(height: "", birthDate: nil, notes: ""))
        let p = try #require(s.context.fetch(FetchDescriptor<BodyProfile>()).first)
        #expect(p.id == BodyProfile.canonicalID && p.heightCm == nil && p.birthDate == nil)
        #expect(try s.context.fetchCount(FetchDescriptor<BodyProfile>()) == 1)
    }
    @Test("Medição, filhos e outbox sobrevivem ao disco e à edição")
    func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "current.store"); var id = UUID(), childID = UUID()
        do {
            let s = try store(url: url); let r = try body(s); id = r.id; childID = r.values[0].id
            _ = try body(s, id: id, value: "81,25")
            #expect(r.values[0].id == childID)
        }
        let reopened = try store(url: url); let r = try #require(reopened.context.fetch(FetchDescriptor<BodyRecord>()).first)
        #expect(r.id == id && r.values[0].id == childID && r.values[0].value == "81.25")
        let pending = try #require(reopened.context.fetch(FetchDescriptor<PendingMutation>()).first)
        #expect(pending.protocolVersion == 2 && pending.payload != nil)
        #expect(BodyStore(store: reopened).delete(r))
        #expect(try reopened.context.fetchCount(FetchDescriptor<BodyValue>()) == 0)
        #expect(try reopened.context.fetch(FetchDescriptor<PendingMutation>()).first?.payload == nil)
    }
    @Test("Rascunhos incompletos ficam fora dos snapshots e pertencem ao arquivo da conta")
    func drafts() throws {
        let a = try store(), b = try store(); let drafts = ProgressDraftStore(store: a)
        #expect(drafts.save(["peso":"80,"], key: "body-new"))
        #expect(drafts.load([String:String].self, key: "body-new")?["peso"] == "80,")
        #expect(ProgressDraftStore(store: b).load([String:String].self, key: "body-new") == nil)
        #expect(try Snapshots.all(in: a.context).isEmpty)
        #expect(drafts.remove(key: "body-new")); #expect(drafts.load([String:String].self, key: "body-new") == nil)
    }
    @Test("Sono usa instantes reais, data de acordar e opcionais")
    func sleep() throws {
        let s = try store(), service = SleepStore(store: s); let id = UUID()
        let start = date("2026-10-17T02:30:00Z"), end = date("2026-10-17T10:00:00Z")
        #expect(service.save(id: id, start: start, end: end, startTimezoneID: "America/Sao_Paulo", endTimezoneID: "America/Sao_Paulo", awakenings: "", quality: nil, notes: ""))
        let r = try #require(s.context.fetch(FetchDescriptor<SleepRecord>()).first)
        #expect(r.duration == 7.5 * 3600 && r.wakeDate == "2026-10-17" && r.awakenings == nil && r.quality == nil)
        #expect(!service.save(id: UUID(), start: start, end: end, startTimezoneID: "GMT", endTimezoneID: "GMT", awakenings: "0", quality: .good, notes: ""))
        #expect(service.save(id: id, start: start, end: end, startTimezoneID: "America/Sao_Paulo", endTimezoneID: "America/Sao_Paulo", awakenings: "0", quality: .good, notes: ""))
        #expect(r.awakenings == 0)
        #expect(!service.save(id: id, start: end, end: start, startTimezoneID: "GMT", endTimezoneID: "GMT", awakenings: "0", quality: nil, notes: ""))
        // New York springs forward: 01:30 → 03:30 is one elapsed hour.
        #expect(date("2026-03-08T07:30:00Z").timeIntervalSince(date("2026-03-08T06:30:00Z")) == 3600)
    }
    @Test("Médias respeitam limiares, janela inclusiva e ausências")
    func averages() throws {
        let end = date("2026-10-17T12:00:00Z")
        let points = (0..<3).map { i in WeightPoint(id: UUID(), date: end.addingTimeInterval(Double(-i) * 86400), value: Decimal(80+i)) }
        #expect(ProgressStatistics.weightMean(Array(points.prefix(2)), endingAt: end, timezoneID: "GMT") == nil)
        #expect(ProgressStatistics.weightMean(points, endingAt: end, timezoneID: "GMT") == 81)
        let nights = (0..<12).map { i -> SleepPoint in
            let e = end.addingTimeInterval(Double(-i) * 86400)
            return .init(id: UUID(), wakeDate: ProgressRules.day(e, timezoneID: "GMT"), start: e.addingTimeInterval(-8*3600), end: e,
                startTimezoneID: "GMT", endTimezoneID: "GMT", awakenings: i < 5 ? 0 : nil)
        }
        #expect(ProgressStatistics.sleepMean(Array(nights.prefix(3)), endingOn: "2026-10-17", days: 7) == nil)
        let weeklyMean = try #require(ProgressStatistics.sleepMean(Array(nights.prefix(4)), endingOn: "2026-10-17", days: 7))
        #expect(abs(weeklyMean - 28_800) < 0.001)
        #expect(ProgressStatistics.sleepMean(Array(nights.prefix(11)), endingOn: "2026-10-17", days: 30) == nil)
        let monthlyMean = try #require(ProgressStatistics.sleepMean(nights, endingOn: "2026-10-17", days: 30))
        #expect(abs(monthlyMean - 28_800) < 0.001)
        #expect(ProgressStatistics.awakeningMean(Array(nights.prefix(4))) == nil)
        #expect(ProgressStatistics.awakeningMean(nights) == 0)
        #expect(ProgressStatistics.clockMeans(Array(nights.prefix(6))).isEmpty)
        #expect(!ProgressStatistics.clockMeans(Array(nights.prefix(7))).isEmpty)
        let duplicate = nights + [nights[0]]
        #expect(ProgressStatistics.unambiguousNights(duplicate).count == 11)
        let circular = try #require(ProgressRules.circularMean([23*60,60]))
        #expect(min(abs(circular),abs(circular-1440)) < 0.001)
        #expect(ProgressRules.circularMean([0,720]) == nil)
    }
    @Test("Falha de disco não deixa uma medição pronta para envio")
    func failedSave() throws {
        struct DiskError: Error {}
        let c = try PersistenceController.makeContainer(inMemory: true)
        let s = WorkoutStore(context: c.mainContext) { _ in throw DiskError() }
        #expect(!BodyStore(store: s).saveRecord(id: UUID(), date: .now, timezoneID: "GMT", values: [(.weight,"80")], method: nil, methodNotes: "", notes: ""))
        #expect(try c.mainContext.fetchCount(FetchDescriptor<BodyRecord>()) == 0)
        #expect(try c.mainContext.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    }

    @Test("Rascunho incompleto reabre no disco, cancela e confirma sem publicar campos parciais")
    func draftReopening() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "draft.store"), key = "body-weight"
        var draft = BodyEntryDraft()
        draft.date = date("2026-10-17T10:00:00Z"); draft.timezoneID = "America/Sao_Paulo"
        draft.values = [.init(kind: .weight, value: "80,")]; draft.notes = "Somente fixture"
        do {
            let s = try store(url: url)
            #expect(ProgressDraftStore(store: s).save(draft, key: key))
            #expect(try Snapshots.all(in: s.context).isEmpty)
            #expect(try s.context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
        }
        do {
            let s = try store(url: url), drafts = ProgressDraftStore(store: s)
            let recovered = try #require(drafts.load(BodyEntryDraft.self, key: key))
            #expect(recovered == draft)
            #expect(!BodyStore(store: s).saveRecord(id: recovered.id, date: recovered.date, timezoneID: recovered.timezoneID,
                values: recovered.values.map { ($0.kind, $0.value) }, method: nil, methodNotes: "", notes: recovered.notes, draftKey: key))
            #expect(drafts.load(BodyEntryDraft.self, key: key) == draft)
            #expect(try Snapshots.all(in: s.context).isEmpty)
            draft.values[0].value = "80,25"
            #expect(BodyStore(store: s).saveRecord(id: draft.id, date: draft.date, timezoneID: draft.timezoneID,
                values: draft.values.map { ($0.kind, $0.value) }, method: nil, methodNotes: "", notes: draft.notes, draftKey: key))
            #expect(drafts.load(BodyEntryDraft.self, key: key) == nil)
            draft.values[0].value = "99,5"
            #expect(drafts.save(draft, key: key))
            #expect(drafts.remove(key: key))
        }
        let s = try store(url: url)
        let record = try #require(s.context.fetch(FetchDescriptor<BodyRecord>()).first)
        #expect(record.id == draft.id && record.values.first?.value == "80.25")
        #expect(try s.context.fetchCount(FetchDescriptor<BodyRecord>()) == 1)
        #expect(try s.context.fetchCount(FetchDescriptor<EntryDraft>()) == 0)
        #expect(try s.context.fetchCount(FetchDescriptor<PendingMutation>()) == 1)
    }

    @Test("Falha ao confirmar uma edição preserva registro, rascunho e fila anteriores", arguments: [true,false])
    func editingFailure(inMemory: Bool) throws {
        struct DiskError: Error {}
        var fail = false
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try PersistenceController.makeContainer(inMemory: inMemory, url: inMemory ? nil : dir.appending(path: "failure.store"))
        let s = WorkoutStore(context: c.mainContext) { context in
            if fail { throw DiskError() }; try context.save()
        }
        let record = try body(s), id = record.id
        #expect(BodyStore(store: s).saveRecord(id: id, date: record.measuredAt, timezoneID: record.timezoneID,
            values: [(.weight,"80,5"),(.waist,"90")], method: nil, methodNotes: "", notes: "Original"))
        let before = try #require(s.context.fetch(FetchDescriptor<PendingMutation>()).first).payload
        #expect(ProgressDraftStore(store: s).save(["value":"81,75"], key: "edit"))
        fail = true
        #expect(!BodyStore(store: s).saveRecord(id: id, date: record.measuredAt, timezoneID: record.timezoneID,
            values: [(.weight,"81,75")], method: nil, methodNotes: "", notes: "Correção", draftKey: "edit"))
        let unchanged = try #require(s.context.fetch(FetchDescriptor<BodyRecord>()).first)
        #expect(unchanged.values.first { $0.kind == .weight }?.value == "80.5")
        #expect(unchanged.values.first { $0.kind == .waist }?.value == "90" && unchanged.values.count == 2)
        #expect(unchanged.notes == "Original")
        #expect(try ProgressSnapshots.capture(kind: .bodyRecord, id: id, in: s.context) == before)
        let persistedContext = ModelContext(c)
        #expect(try persistedContext.fetch(FetchDescriptor<BodyValue>()).first { $0.kind == .weight }?.value == "80.5")
        #expect(ProgressDraftStore(store: s).load([String:String].self, key: "edit")?["value"] == "81,75")
        #expect(try s.context.fetch(FetchDescriptor<PendingMutation>()).first?.payload == before)
        #expect(try s.context.fetch(FetchDescriptor<SyncRecord>()).first?.localPayload == before)
        fail = false
        #expect(BodyStore(store: s).saveRecord(id: id, date: unchanged.measuredAt, timezoneID: unchanged.timezoneID,
            values: [(.weight,"81,75")], method: nil, methodNotes: "", notes: "", draftKey: "edit"))
        #expect(unchanged.values.first?.value == "81.75")
        #expect(ProgressDraftStore(store: s).load([String:String].self, key: "edit") == nil)
    }

    @Test("Janelas incluem o primeiro dia, excluem os dias vizinhos e respeitam o fuso")
    func windowBoundaries() throws {
        let samples: [(String, Int)] = [
            ("2026-03-02T04:59:59Z", 900), ("2026-03-02T05:00:00Z", 80),
            ("2026-03-08T05:00:00Z", 82), ("2026-03-09T03:59:59Z", 84), ("2026-03-09T04:00:00Z", 900)
        ]
        let points = samples.map { WeightPoint(id: UUID(), date: date($0.0), value: Decimal($0.1)) }
        #expect(ProgressStatistics.weightMean(points, endingAt: date("2026-03-08T15:00:00Z"), timezoneID: "America/New_York") == 82)
        let nights = ["2026-10-10","2026-10-11","2026-10-14","2026-10-16","2026-10-17","2026-10-18"].map { day in
            SleepPoint(id: UUID(), wakeDate: day, start: date(day + "T00:00:00Z"), end: date(day + "T08:00:00Z"),
                startTimezoneID: "GMT", endTimezoneID: "GMT", awakenings: nil)
        }
        #expect(ProgressStatistics.nights(nights, endingOn: "2026-10-17", days: 7).map(\.wakeDate) == ["2026-10-11","2026-10-14","2026-10-16","2026-10-17"])
        #expect(ProgressStatistics.nights(nights, endingOn: "2026-10-17", days: 7).allSatisfy { $0.awakenings == nil })
    }

    @Test("Falha ao apagar ou limpar preserva o agregado e permite tentar novamente", arguments: [EntityKind.bodyProfile,.bodyRecord,.sleep])
    func destructiveFailure(kind: EntityKind) throws {
        struct DiskError: Error {}
        var fail = false
        let c = try PersistenceController.makeContainer(inMemory: true)
        let s = WorkoutStore(context: c.mainContext) { context in
            if fail { throw DiskError() }; try context.save()
        }
        let id = kind == .bodyProfile ? BodyProfile.canonicalID : UUID()
        switch kind {
        case .bodyProfile:
            #expect(BodyStore(store: s).saveProfile(height: "178", birthDate: "1990-02-28", notes: "Fixture"))
        case .bodyRecord:
            #expect(BodyStore(store: s).saveRecord(id: id, date: date("2026-10-17T10:00:00Z"), timezoneID: "America/Sao_Paulo",
                values: [(.weight,"80,5"),(.skeletalMuscleMass,"31,2")], method: .dexa, methodNotes: "Fixture", notes: "Original"))
        case .sleep:
            // The local clock repeats an hour in New York; elapsed time is two hours.
            #expect(SleepStore(store: s).save(id: id, start: date("2026-11-01T05:30:00Z"), end: date("2026-11-01T07:30:00Z"),
                startTimezoneID: "America/New_York", endTimezoneID: "America/New_York", awakenings: "", quality: nil, notes: "Fixture"))
            let duration = try #require(s.context.fetch(FetchDescriptor<SleepRecord>()).first).duration
            #expect(abs(duration - 7_200) < 0.001)
        default: Issue.record("Tipo inesperado"); return
        }
        let before = try #require(try ProgressSnapshots.capture(kind: kind, id: id, in: s.context))
        let pending = try #require(s.context.fetch(FetchDescriptor<PendingMutation>()).first)
        let operationID = pending.id, pendingPayload = pending.payload
        func remove() throws -> Bool {
            switch kind {
            case .bodyProfile: return BodyStore(store: s).saveProfile(height: "", birthDate: nil, notes: "")
            case .bodyRecord: return BodyStore(store: s).delete(try #require(s.context.fetch(FetchDescriptor<BodyRecord>()).first))
            case .sleep: return SleepStore(store: s).delete(try #require(s.context.fetch(FetchDescriptor<SleepRecord>()).first))
            default: return false
            }
        }
        fail = true
        #expect(try !remove())
        #expect(try ProgressSnapshots.capture(kind: kind, id: id, in: s.context) == before)
        #expect(try ProgressSnapshots.capture(kind: kind, id: id, in: ModelContext(c)) == before)
        #expect(try s.context.fetch(FetchDescriptor<PendingMutation>()).first?.id == operationID)
        #expect(try s.context.fetch(FetchDescriptor<PendingMutation>()).first?.payload == pendingPayload)
        fail = false
        #expect(try remove())
        if kind == .bodyProfile {
            let profile = try #require(s.context.fetch(FetchDescriptor<BodyProfile>()).first)
            #expect(profile.id == id && profile.heightCm == nil && profile.birthDate == nil && profile.notes.isEmpty)
        } else {
            #expect(try ProgressSnapshots.capture(kind: kind, id: id, in: s.context) == nil)
            #expect(try s.context.fetch(FetchDescriptor<PendingMutation>()).first?.payload == nil)
        }
        #expect(try s.context.fetchCount(FetchDescriptor<BodyValue>()) == 0)
    }
}
