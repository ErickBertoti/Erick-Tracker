import Foundation
import SwiftData
import Testing
#if os(macOS)
@testable import Erick_Tracker
#else
@testable import Erick_Tracker_iOS
#endif

@MainActor @Suite("Fase 3: protocolo compatível e conflitos", .serialized)
struct ProgressSyncTests {
    private func store(url: URL? = nil) throws -> WorkoutStore {
        let container = try PersistenceController.makeContainer(inMemory: url == nil, url: url)
        return WorkoutStore(context: container.mainContext)
    }
    @Test("Processo dos testes não cria autenticação nem abre dados pessoais")
    func isolatedTestHost() throws {
        #expect(TestRuntime.isUnitTesting)
        let app = AppController()
        #expect(app.client == nil && app.sync == nil && app.userID == nil && !app.isRestoring)
        let c = try #require(app.persistence.container)
        let onlyMemory = c.configurations.allSatisfy { $0.isStoredInMemoryOnly }
        #expect(onlyMemory)
        #expect(try Snapshots.all(in:c.mainContext).isEmpty)
    }
    private func body(_ s: WorkoutStore, id: UUID = UUID(), value: String = "80,5") throws -> UUID {
        #expect(BodyStore(store:s).saveRecord(id:id,date:Date(timeIntervalSince1970:1_792_224_000),timezoneID:"GMT",
            values:[(.weight,value),(.waist,"90")],method:nil,methodNotes:"",notes:"Fixture")); return id
    }
    private func sleep(_ s: WorkoutStore, id: UUID = UUID(), hours: Double = 8) throws -> UUID {
        let end = Date(timeIntervalSince1970:1_792_231_200)
        #expect(SleepStore(store:s).save(id:id,start:end.addingTimeInterval(-hours*3600),end:end,
            startTimezoneID:"GMT",endTimezoneID:"GMT",awakenings:"0",quality:.good,notes:"Fixture")); return id
    }
    @Test("Corpo recebe correção offline e repete resposta perdida sem duplicar")
    func bodyReplay() async throws {
        let a = try store(), b = try store(), cloud = ProgressTestCloud()
        let sa = SyncEngine(store:a,transport:cloud), sb = SyncEngine(store:b,transport:cloud)
        let id = try body(a); cloud.base.loseNextResponse = true
        await sa.sync(); #expect(sa.error != nil)
        _ = try body(a,id:id,value:"81,75")
        let resumed = SyncEngine(store:a,transport:cloud); await resumed.sync(); await sb.sync(); await resumed.sync()
        let rows = try b.context.fetch(FetchDescriptor<BodyRecord>())
        #expect(rows.count == 1 && rows[0].id == id && rows[0].values.first { $0.kind == .weight }?.value == "81.75")
        #expect(try b.context.fetchCount(FetchDescriptor<BodyValue>()) == 2)
        #expect(resumed.pendingCount == 0 && resumed.error == nil)
        #expect(cloud.base.changes.filter { $0.kind == .bodyRecord }.count == 2)
    }
    @Test("Manter ambas gera IDs novos para a medição e seus valores")
    func bothBodies() async throws {
        let a = try store(), b = try store(), cloud = ProgressTestCloud()
        let sa = SyncEngine(store:a,transport:cloud), sb = SyncEngine(store:b,transport:cloud)
        let id = try body(a); await sa.sync(); await sb.sync()
        _ = try body(a,id:id,value:"82"); _ = try body(b,id:id,value:"83")
        await sa.sync(); await sb.sync()
        let conflict = try #require(b.context.fetch(FetchDescriptor<SyncConflict>()).first)
        sb.resolve(conflict,choosing:.both); await sb.sync(); await sa.sync()
        let rows = try a.context.fetch(FetchDescriptor<BodyRecord>())
        #expect(rows.count == 2 && Set(rows.map(\.id)).count == 2)
        #expect(Set(rows.flatMap(\.values).map(\.id)).count == 4)
        #expect(Set(rows.compactMap { $0.values.first { $0.kind == .weight }?.value }) == ["82","83"])
        #expect(sb.conflictCount == 0)
    }
    @Test("Noites concorrentes preservam candidatos e resolvem para uma noite", arguments: [true,false])
    func duplicateNights(useLocal: Bool) async throws {
        let a = try store(), b = try store(), cloud = ProgressTestCloud()
        let sa = SyncEngine(store:a,transport:cloud), sb = SyncEngine(store:b,transport:cloud)
        let remoteID = try sleep(a,hours:8), localID = try sleep(b,hours:7)
        await sa.sync(); await sb.sync()
        let conflict = try #require(b.context.fetch(FetchDescriptor<SyncConflict>()).first)
        #expect(conflict.reasonRaw == "duplicateNight" && conflict.entityID == localID && conflict.competingID == remoteID)
        let candidates = try b.context.fetch(FetchDescriptor<SleepRecord>())
        #expect(candidates.count == 2 && conflict.localPayload != nil && conflict.competingPayload != nil)
        let stats = candidates.map { SleepPoint(id:$0.id,wakeDate:$0.wakeDate,start:$0.startedAt,end:$0.endedAt,
            startTimezoneID:$0.startTimezoneID,endTimezoneID:$0.endTimezoneID,awakenings:$0.awakenings) }
        #expect(ProgressStatistics.unambiguousNights(stats).isEmpty)
        sb.resolve(conflict,choosing:useLocal ? .local : .remote)
        await sb.sync(); await sa.sync()
        for s in [a,b] {
            let rows = try s.context.fetch(FetchDescriptor<SleepRecord>())
            #expect(rows.count == 1 && rows[0].id == remoteID && rows[0].duration == (useLocal ? 7 : 8)*3600)
        }
        #expect(sb.conflictCount == 0 && sb.pendingCount == 0 && sb.error == nil)
    }
    @Test("Excluir uma edição de noite conflitante não perde o tombstone necessário")
    func deletedDuplicate() async throws {
        let a = try store(), b = try store(), cloud = ProgressTestCloud()
        let sa = SyncEngine(store:a,transport:cloud), sb = SyncEngine(store:b,transport:cloud)
        let ownID = try sleep(b,hours:6); await sb.sync()
        await sa.sync()
        // Another day is created on A while B moves its existing record offline.
        let nextEnd = Date(timeIntervalSince1970:1_792_231_200 + 86400)
        #expect(SleepStore(store:a).save(id:UUID(),start:nextEnd.addingTimeInterval(-8*3600),end:nextEnd,startTimezoneID:"GMT",endTimezoneID:"GMT",awakenings:"",quality:nil,notes:""))
        #expect(SleepStore(store:b).save(id:ownID,start:nextEnd.addingTimeInterval(-7*3600),end:nextEnd,startTimezoneID:"GMT",endTimezoneID:"GMT",awakenings:"",quality:nil,notes:""))
        await sa.sync(); await sb.sync()
        let conflict = try #require(b.context.fetch(FetchDescriptor<SyncConflict>()).first { $0.reasonRaw == "duplicateNight" })
        let local = try #require(b.context.fetch(FetchDescriptor<SleepRecord>()).first { $0.id == ownID })
        #expect(SleepStore(store:b).delete(local)); sb.resolve(conflict,choosing:.local)
        await sb.sync(); await sa.sync()
        #expect(try a.context.fetchCount(FetchDescriptor<SleepRecord>()) == 1)
        #expect(cloud.base.current["sleep:\(ownID.uuidString)"]?.deleted == true)
    }
    @Test("Cursor v1 adiantado não oculta dados novos; operação migrada mantém v1")
    func cursorAndVersion() async throws {
        let a = try store(), b = try store(), cloud = ProgressTestCloud()
        _ = try body(a); await SyncEngine(store:a,transport:cloud).sync()
        let cursor = SyncCursor(); cursor.revision = 1000; b.context.insert(cursor)
        let p = try #require(b.createProgram(name:"Legado"))
        let pending = try #require(b.context.fetch(FetchDescriptor<PendingMutation>()).first { $0.entityID == p.id })
        pending.protocolVersion = 1; try b.context.save()
        let engine = SyncEngine(store:b,transport:cloud); await engine.sync()
        #expect(try b.context.fetchCount(FetchDescriptor<BodyRecord>()) == 1)
        #expect(cloud.base.requests.values.first { $0.entityID == p.id }?.protocolVersion == 1)
        let cursors = try b.context.fetch(FetchDescriptor<SyncCursor>())
        #expect(cursors.first { $0.key == "changes-v1" }?.revision == 1000)
        #expect(cursors.first { $0.key == "changes-v2" }?.revision == 2)
    }
    @Test("Tipo desconhecido interrompe a página sem avançar o cursor")
    func futureType() async throws {
        let a = try store(), cloud = ProgressTestCloud(); _ = try body(a)
        let engine = SyncEngine(store:a,transport:cloud); await engine.sync()
        let before = try #require(a.context.fetch(FetchDescriptor<SyncCursor>()).first { $0.key == "changes-v2" }).revision
        cloud.base.append(kind:.unknown,id:UUID(),payload:.object([:]))
        await engine.sync()
        #expect(engine.error == SyncFailure.invalidResponse.localizedDescription)
        #expect(try a.context.fetch(FetchDescriptor<SyncCursor>()).first { $0.key == "changes-v2" }?.revision == before)
    }
    @Test("Salvar remove o rascunho na mesma gravação; conta separada começa vazia")
    func atomicDraft() throws {
        let s = try store(); let drafts = ProgressDraftStore(store:s)
        #expect(drafts.save(["value":"80,"],key:"new-body"))
        #expect(BodyStore(store:s).saveRecord(id:UUID(),date:.now,timezoneID:"GMT",values:[(.weight,"80,5")],method:nil,methodNotes:"",notes:"",draftKey:"new-body"))
        #expect(drafts.load([String:String].self,key:"new-body") == nil)
        #expect(try s.context.fetchCount(FetchDescriptor<PendingMutation>()) == 1)
        let another = try store(); #expect(try Snapshots.all(in:another.context).isEmpty)
        #expect(ProgressRules.editable("1234.5") == "1234,5")
    }

    @Test("Sono offline reabre, repete envio interrompido e recebe correção sem duplicar")
    func sleepDiskRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aURL = directory.appending(path: "a.store"), bURL = directory.appending(path: "b.store")
        let cloud = ProgressTestCloud(), id = UUID()
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-12-31T14:30:00Z"))
        let end = try #require(formatter.date(from: "2026-12-31T22:00:00Z"))
        var operationID: UUID?
        do {
            let a = try store(url: aURL)
            #expect(SleepStore(store: a).save(id: id, start: start, end: end,
                startTimezoneID: "Asia/Tokyo", endTimezoneID: "Asia/Tokyo", awakenings: "", quality: nil, notes: "Fixture offline"))
        }
        do {
            let a = try store(url: aURL), engine = SyncEngine(store: a, transport: cloud)
            let local = try #require(a.context.fetch(FetchDescriptor<SleepRecord>()).first)
            #expect(local.id == id && local.wakeDate == "2027-01-01" && local.awakenings == nil && local.quality == nil)
            operationID = try #require(a.context.fetch(FetchDescriptor<PendingMutation>()).first).id
            cloud.base.loseNextResponse = true
            await engine.sync()
            #expect(engine.error != nil)
            #expect(try a.context.fetch(FetchDescriptor<PendingMutation>()).first?.hasBeenSent == true)
        }
        do {
            let a = try store(url: aURL), b = try store(url: bURL)
            #expect(try a.context.fetch(FetchDescriptor<PendingMutation>()).first?.id == operationID)
            let sa = SyncEngine(store: a, transport: cloud), sb = SyncEngine(store: b, transport: cloud)
            await sa.sync(); await sb.sync()
            #expect(sa.pendingCount == 0 && sb.error == nil)
            let remote = try #require(b.context.fetch(FetchDescriptor<SleepRecord>()).first)
            #expect(remote.id == id && remote.startedAt == start && remote.endedAt == end && remote.duration == 27_000)
            #expect(remote.startTimezoneID == "Asia/Tokyo" && remote.endTimezoneID == "Asia/Tokyo" && remote.wakeDate == "2027-01-01")
            #expect(remote.awakenings == nil && remote.quality == nil && remote.notes == "Fixture offline")
            #expect(SleepStore(store: b).save(id: id, start: start, end: end,
                startTimezoneID: remote.startTimezoneID, endTimezoneID: remote.endTimezoneID,
                awakenings: "0", quality: .excellent, notes: "Correção fictícia"))
        }
        do {
            let a = try store(url: aURL), b = try store(url: bURL)
            let sb = SyncEngine(store: b, transport: cloud), sa = SyncEngine(store: a, transport: cloud)
            await sb.sync(); await sa.sync(); await sb.sync()
            for s in [a,b] {
                let rows = try s.context.fetch(FetchDescriptor<SleepRecord>())
                #expect(rows.count == 1 && rows[0].id == id)
                #expect(rows[0].awakenings == 0 && rows[0].quality == .excellent && rows[0].notes == "Correção fictícia")
                #expect(rows[0].wakeDate == "2027-01-01" && rows[0].startedAt == start && rows[0].endedAt == end)
            }
            #expect(cloud.base.changes.filter { $0.kind == .sleep }.count == 2)
            #expect(sb.pendingCount == 0 && sa.pendingCount == 0 && sa.conflictCount == 0 && sb.conflictCount == 0)
        }
    }
}

@MainActor final class ProgressTestCloud: CloudTransport {
    let base = TestCloud()
    private var duplicateReceipts: [UUID:MutationReply] = [:]
    private var duplicateRequests: [UUID:Data] = [:]
    func apply(_ request: MutationRequest) async throws -> MutationReply {
        if let receipt = duplicateReceipts[request.mutationID] {
            #expect(duplicateRequests[request.mutationID] == (try SnapshotCodec.encode(request))); return receipt
        }
        if request.kind == .sleep, !request.deleted, let payload = request.payload {
            let incoming = try SnapshotCodec.decode(SleepSnapshot.self,from:SnapshotCodec.encode(payload))
            let key = "sleep:\(request.entityID.uuidString)", own = base.current[key]
            if (own?.revision ?? 0) == request.baseRevision, own?.deleted != true {
                for change in base.current.values where change.kind == .sleep && !change.deleted && change.entityID != request.entityID {
                    guard let value = change.payload else { continue }
                    let other = try SnapshotCodec.decode(SleepSnapshot.self,from:SnapshotCodec.encode(value))
                    if incoming.wakeDate == other.wakeDate {
                        let reply = MutationReply(status:"duplicateNight",revision:own?.revision ?? 0,payload:own?.payload,deleted:own?.deleted ?? true,
                            competingEntityID:other.id,competingRevision:change.revision,competingPayload:value)
                        duplicateReceipts[request.mutationID] = reply; duplicateRequests[request.mutationID] = try SnapshotCodec.encode(request)
                        return reply
                    }
                }
            }
        }
        return try await base.apply(request)
    }
    func pull(after revision: Int64,limit:Int) async throws -> [RemoteChange] { try await base.pull(after:revision,limit:limit) }
}
