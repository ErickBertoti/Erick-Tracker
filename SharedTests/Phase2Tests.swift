import Foundation
import SwiftData
import Testing
#if os(macOS)
@testable import Erick_Tracker
#else
@testable import Erick_Tracker_iOS
#endif

@MainActor @Suite("Fase 2: sessões, migração e sincronização", .serialized)
struct Phase2Tests {
    private func store(url: URL? = nil) throws -> WorkoutStore {
        let container = try PersistenceController.makeContainer(inMemory: url == nil, url: url)
        return WorkoutStore(context: container.mainContext)
    }
    private func fixture(_ store: WorkoutStore) throws -> WorkoutTemplate {
        let program = try #require(store.createProgram(name: "Programa"))
        let exercise = try #require(store.createExercise(name: "Supino", primaryMuscle: "Peito"))
        let workout = try #require(store.createWorkout(name: "Treino A", program: program))
        let item = store.addExercise(exercise, to: workout)
        let set = try #require(item.orderedSets.first)
        store.updateSet(set) { set.kind = .dropSet; set.reps = "12 + 10"; set.load = "15 → 10" }
        return workout
    }
    @Test("V1 migra no disco sem alterar IDs, relações ou textos")
    func migration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "legacy.store")
        var ids: [UUID] = []
        do {
            let schema = Schema(versionedSchema: TrackerSchemaV1.self)
            let config = ModelConfiguration("ErickTracker", schema: schema, url: url, cloudKitDatabase: .none)
            let old = try ModelContainer(for: schema, configurations: [config]); let c = old.mainContext
            let p = Program(name: "Programa antigo"); c.insert(p)
            let e = Exercise(name: "Elevação lateral"); c.insert(e)
            let w = WorkoutTemplate(name: "Treino legado", program: p); c.insert(w)
            let i = WorkoutItem(exercise: e); c.insert(i); i.workout = w; i.repRange = "6–8"
            let s = SetTemplate(kind: .dropSet, reps: "12 + 10", load: "15 → 10"); c.insert(s); s.item = i
            ids = [p.id,e.id,w.id,i.id,s.id]; try c.save()
        }
        let current = try store(url: url)
        let w = try #require(current.context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        let i = try #require(w.items.first); let s = try #require(i.sets.first)
        #expect([w.program!.id,i.exercise!.id,w.id,i.id,s.id] == ids)
        #expect(i.repRange == "6–8" && s.reps == "12 + 10" && s.load == "15 → 10")
        #expect(try current.context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
        #expect(current.save()); #expect(try current.context.fetchCount(FetchDescriptor<PendingMutation>()) == 3)
    }
    @Test("Prescrição e histórico sobrevivem à edição e exclusão do modelo")
    func independentHistory() throws {
        let s = try store(); let w = try fixture(s); let sessions = SessionStore(store: s)
        let session = try #require(sessions.start(w)); let original = session.prescription
        let set = try #require(session.orderedExercises.first?.orderedSets.first)
        let p = try #require(set.orderedSegments.first)
        #expect(sessions.update(p, reps: "12", load: "15,5"))
        sessions.addSegment(to: set)
        let second = try #require(set.orderedSegments.last)
        #expect(sessions.update(second, reps: "10", load: "10"))
        #expect(sessions.mark(set, as: .completed)); sessions.finish(session)
        s.renameWorkout(w, name: "Novo nome"); s.deleteWorkout(w)
        #expect(session.prescription == original && session.name == "Treino A")
        #expect(session.completedSetCount == 1 && set.segments.count == 2)
        #expect(p.loadKg == "15.5" && second.reps == 10)
        let data = try SnapshotCodec.encode(Snapshots.session(session))
        let restored = try store(); try Snapshots.apply(kind: .session, id: session.id, payload: data, in: restored.context)
        try restored.context.save()
        let copy = try #require(restored.context.fetch(FetchDescriptor<WorkoutSession>()).first)
        #expect(copy.prescription == original && copy.completedSetCount == 1)
        // Applying the same snapshot twice must keep graph identities and counts.
        try Snapshots.apply(kind: .session, id: session.id, payload: data, in: restored.context); try restored.context.save()
        #expect(try restored.context.fetchCount(FetchDescriptor<SetLogSegment>()) == 2)
    }
    @Test("Valores numéricos preservam ausência e zero; expressões não viram carga")
    func values() throws {
        let s = try store(); let w = try fixture(s); let sessions = SessionStore(store: s)
        let session = try #require(sessions.start(w)); let set = session.exercises[0].sets[0]; let p = set.segments[0]
        #expect(!sessions.mark(set, as: .completed))
        #expect(sessions.update(p, reps: "8", load: "")); #expect(p.loadKg == nil)
        #expect(sessions.update(p, reps: "8", load: "0")); #expect(p.loadKg == "0")
        #expect(!sessions.update(p, reps: "8,5", load: "10"))
        #expect(!sessions.update(p, reps: "8", load: "15 → 10"))
        #expect(!sessions.update(p, reps: "8", load: "NaN"))
        #expect(set.prescribedReps == "12 + 10" && set.prescribedLoad == "15 → 10")
    }
    @Test("Descanso, pausa, conclusão e numeração usam estado persistido")
    func lifecycle() throws {
        let s = try store(); let w = try fixture(s); let sessions = SessionStore(store: s)
        let session = try #require(sessions.start(w))
        #expect(sessions.start(w)?.id == session.id)
        let e = session.exercises[0]; let set = e.sets[0]
        #expect(sessions.update(set.segments[0], reps: "8", load: "12,5")); #expect(sessions.mark(set, as: .completed))
        #expect(session.restEndsAt != nil)
        sessions.pause(session); #expect(session.restEndsAt == nil && session.pausedRestSeconds != nil)
        sessions.setRest(session, seconds: 60); #expect(session.pausedRestSeconds == 60)
        sessions.resume(session); #expect(session.restEndsAt != nil && session.pausedAt == nil)
        sessions.addSet(to: e); let warmup = try #require(e.orderedSets.last)
        sessions.update(warmup) { warmup.kind = .warmup }
        #expect(e.number(for: warmup) == nil && e.number(for: set) == 1)
        sessions.finish(session); #expect(session.status == .completed && session.restEndsAt == nil)
        #expect(warmup.status == .skipped && sessions.activeSession == nil)
    }
    @Test("Reabertura recupera sessão e fila; lojas de contas são independentes")
    func diskResume() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "account-a.store"); var id = UUID()
        do {
            let s = try store(url: url); let sessions = SessionStore(store: s)
            let session = try #require(sessions.start(fixture(s))); id = session.id
            #expect(sessions.update(session.exercises[0].sets[0].segments[0], reps: "9", load: "21,25"))
            sessions.setRest(session, seconds: 90)
        }
        let reopened = try store(url: url); let session = try #require(SessionStore(store: reopened).activeSession)
        #expect(session.id == id && session.restEndsAt != nil)
        #expect(session.exercises[0].sets[0].segments[0].loadKg == "21.25")
        #expect(try reopened.context.fetchCount(FetchDescriptor<PendingMutation>()) == 4)
        let other = try store(url: dir.appending(path: "account-b.store"))
        #expect(try other.context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
        #expect(try other.context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 0)
    }
    @Test("Resposta perdida repete o mesmo envio sem criar duplicatas")
    func lostResponse() async throws {
        let s = try store(); _ = try fixture(s); let cloud = TestCloud(); cloud.loseNextResponse = true
        let engine = SyncEngine(store: s, transport: cloud)
        await engine.sync(); #expect(engine.error != nil)
        let attempted = try #require(s.context.fetch(FetchDescriptor<PendingMutation>()).first { $0.hasBeenSent })
        let immutableID = attempted.id
        await engine.sync()
        #expect(engine.error == nil && engine.pendingCount == 0)
        #expect(cloud.receipts[immutableID] != nil && cloud.changes.count == 3)
    }
    @Test("Resposta perdida seguida de nova edição confirma o envio antigo antes de receber mudanças")
    func lostResponseThenEdit() async throws {
        let s = try store(); let program = try #require(s.createProgram(name: "Primeiro nome"))
        let cloud = TestCloud(); cloud.loseNextResponse = true
        let engine = SyncEngine(store: s, transport: cloud)
        await engine.sync(); #expect(engine.error != nil)
        s.renameProgram(program, name: "Nome mais recente")
        #expect(engine.pendingCount == 2)
        await engine.sync()
        #expect(engine.error == nil && engine.pendingCount == 0 && engine.conflictCount == 0)
        let remote = try #require(cloud.changes.last?.payload)
        let received = try SnapshotCodec.decode(ProgramSnapshot.self, from: SnapshotCodec.encode(remote))
        #expect(received.name == "Nome mais recente" && cloud.changes.count == 2)
    }
    @Test("Excluir programa sincroniza treinos avulsos sem gerar conflito com a própria alteração")
    func deleteProgram() async throws {
        let s = try store(); let workout = try fixture(s); let cloud = TestCloud()
        let engine = SyncEngine(store: s, transport: cloud); await engine.sync()
        s.deleteProgram(try #require(workout.program)); await engine.sync()
        #expect(engine.error == nil && engine.pendingCount == 0 && engine.conflictCount == 0)
        #expect(workout.program == nil)
        let other = try store(); let otherSync = SyncEngine(store: other, transport: cloud); await otherSync.sync()
        #expect(try other.context.fetchCount(FetchDescriptor<Program>()) == 0)
        #expect(try other.context.fetch(FetchDescriptor<WorkoutTemplate>()).first?.program == nil)
    }
    @Test("Exclusão remota de programa preserva edição local do treino")
    func remoteProgramRemoval() async throws {
        let a = try store(); let workout = try fixture(a); let cloud = TestCloud()
        let sa = SyncEngine(store: a, transport: cloud); await sa.sync()
        let b = try store(); let sb = SyncEngine(store: b, transport: cloud); await sb.sync()
        a.renameWorkout(workout, name: "Minha edição offline")
        let program = try #require(b.context.fetch(FetchDescriptor<Program>()).first)
        // Simulate the server's transactional cascade without creating a separate
        // client-side template edit (which would change its updatedAt).
        let change = try #require(cloud.current["workout:\(workout.id)"])
        var snapshot = try SnapshotCodec.decode(WorkoutSnapshot.self, from: SnapshotCodec.encode(change.payload))
        snapshot.programID = nil
        cloud.append(kind: .program, id: program.id, payload: nil)
        cloud.append(kind: .workout, id: workout.id, payload: try SnapshotCodec.decode(JSONValue.self, from: SnapshotCodec.encode(snapshot)))
        await sa.sync()
        #expect(sa.error == nil && sa.pendingCount == 0 && sa.conflictCount == 0)
        #expect(workout.program == nil && workout.name == "Minha edição offline")
    }
    @Test("Duas cópias sincronizam uma sessão concluída offline e suas correções")
    func twoDevices() async throws {
        let mac = try store(); let w = try fixture(mac); let cloud = TestCloud()
        let macSync = SyncEngine(store: mac, transport: cloud); await macSync.sync()
        let phone = try store(); let phoneSync = SyncEngine(store: phone, transport: cloud); await phoneSync.sync()
        let planned = try #require(phone.context.fetch(FetchDescriptor<WorkoutTemplate>()).first { $0.id == w.id })
        let sessions = SessionStore(store: phone); let session = try #require(sessions.start(planned))
        let set = session.exercises[0].sets[0]
        #expect(sessions.update(set.segments[0], reps: "10", load: "20")); sessions.mark(set, as: .completed); sessions.finish(session)
        await phoneSync.sync(); await macSync.sync()
        let received = try #require(mac.context.fetch(FetchDescriptor<WorkoutSession>()).first)
        #expect(received.id == session.id && received.exercises[0].sets[0].segments[0].reps == 10)
        #expect(sessions.update(set.segments[0], reps: "11", load: "20,5"))
        await phoneSync.sync(); await macSync.sync()
        #expect(received.exercises[0].sets[0].segments[0].reps == 11)
        #expect(try mac.context.fetchCount(FetchDescriptor<WorkoutSession>()) == 1)
        #expect(macSync.pendingCount == 0 && phoneSync.pendingCount == 0)
        #expect(macSync.error == nil && phoneSync.error == nil)
    }
    @Test("Conflitos preservam versões; manter ambos cria IDs novos em todos os filhos")
    func conflictCopies() async throws {
        let a = try store(); let workout = try fixture(a); let cloud = TestCloud()
        let sa = SyncEngine(store: a, transport: cloud); await sa.sync()
        let b = try store(); let sb = SyncEngine(store: b, transport: cloud); await sb.sync()
        let remote = try #require(b.context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        a.renameWorkout(workout, name: "Versão local"); b.renameWorkout(remote, name: "Versão remota")
        await sb.sync(); await sa.sync()
        let conflict = try #require(a.context.fetch(FetchDescriptor<SyncConflict>()).first)
        #expect(workout.name == "Versão local" && conflict.remotePayload != nil)
        sa.resolve(conflict, choosing: .both); await sa.sync()
        let all = try a.context.fetch(FetchDescriptor<WorkoutTemplate>())
        #expect(all.count == 2 && all.contains { $0.name == "Versão remota" })
        let copy = try #require(all.first { $0.id != workout.id })
        #expect(copy.items[0].id != workout.items[0].id && copy.items[0].sets[0].id != workout.items[0].sets[0].id)
        #expect(copy.items[0].exercise?.id == workout.items[0].exercise?.id)
        #expect(sa.conflictCount == 0 && sa.error == nil)
    }
    @Test("Exclusão offline e nova referência remota preservam ambos até escolher arquivamento")
    func deletedExerciseWithNewReference() async throws {
        let a = try store(); let exercise = try #require(a.createExercise(name: "Remada")); let cloud = TestCloud()
        let sa = SyncEngine(store: a, transport: cloud); await sa.sync()
        let b = try store(); let sb = SyncEngine(store: b, transport: cloud); await sb.sync()
        #expect(a.deleteExercise(exercise))
        let remoteExercise = try #require(b.context.fetch(FetchDescriptor<Exercise>()).first)
        let workout = try #require(b.createWorkout(name: "Treino novo")); b.addExercise(remoteExercise, to: workout)
        await sb.sync(); await sa.sync()
        #expect(sa.error == nil && sa.conflictCount == 2)
        let conflicts = try a.context.fetch(FetchDescriptor<SyncConflict>())
        let exerciseConflict = try #require(conflicts.first { $0.kindRaw == "exercise" })
        let workoutConflict = try #require(conflicts.first { $0.kindRaw == "workout" })
        #expect(exerciseConflict.localPayload == nil && workoutConflict.remotePayload != nil)
        sa.resolve(exerciseConflict, choosing: .archiveExercise)
        sa.resolve(workoutConflict, choosing: .remote)
        await sa.sync()
        let received = try #require(a.context.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        #expect(received.items.first?.exercise?.isArchived == true)
        #expect(sa.error == nil && sa.conflictCount == 0 && sa.pendingCount == 0)
    }
    @Test("Falha de disco impede envio de alterações não confirmadas")
    func saveFailure() async throws {
        struct DiskError: Error { }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let s = WorkoutStore(context: container.mainContext) { _ in throw DiskError() }
        _ = s.createExercise(name: "Não salvo")
        let cloud = TestCloud(); let sync = SyncEngine(store: s, transport: cloud); await sync.sync()
        #expect(cloud.changes.isEmpty && s.saveError != nil)
    }
    @Test("Trocar a conta durante uma requisição nunca envia dados sob a outra identidade")
    func accountSwitchDuringRequest() async throws {
        let owner = UUID(); let fixture = AuthTransportFixture(owner: owner)
        let transport = SupabaseTransport(ownerID: owner,
            identity: { await fixture.identity() }, fetch: { request in await fixture.fetch(request) })
        let first = Task { try await transport.pull(after: 0, limit: 100) }
        await fixture.waitForRequest()
        await fixture.changeAccountAndCompleteRequest()
        #expect(try await first.value.isEmpty)
        do {
            _ = try await transport.pull(after: 0, limit: 100)
            Issue.record("A requisição da conta anterior não foi bloqueada")
        } catch AccountFailure.accountChanged { }
        #expect(await fixture.authorizationHeaders == ["Bearer fixture-token-a"])
    }
}

private actor AuthTransportFixture {
    private var current: SupabaseTransport.Identity
    private var requestStarted: CheckedContinuation<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?
    var authorizationHeaders: [String] = []
    init(owner: UUID) { current = .init(userID: owner, accessToken: "fixture-token-a") }
    func identity() -> SupabaseTransport.Identity { current }
    func fetch(_ request: URLRequest) async -> (Data, URLResponse) {
        authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        requestStarted?.resume(); requestStarted = nil
        await withCheckedContinuation { finish = $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type":"application/json"])!
        return (Data("[]".utf8), response)
    }
    func waitForRequest() async {
        if authorizationHeaders.isEmpty { await withCheckedContinuation { requestStarted = $0 } }
    }
    func changeAccountAndCompleteRequest() {
        current = .init(userID: UUID(), accessToken: "fixture-token-b")
        finish?.resume(); finish = nil
    }
}

@MainActor final class TestCloud: CloudTransport {
    var changes: [RemoteChange] = []
    var receipts: [UUID: MutationReply] = [:]
    var requests: [UUID: MutationRequest] = [:]
    var current: [String: RemoteChange] = [:]
    var loseNextResponse = false
    func append(kind: EntityKind, id: UUID, payload: JSONValue?) {
        let change = RemoteChange(revision: Int64(changes.count + 1), kind: kind, entityID: id, payload: payload, deleted: payload == nil)
        changes.append(change); current["\(kind.rawValue):\(id)"] = change
    }
    func apply(_ request: MutationRequest) async throws -> MutationReply {
        if let receipt = receipts[request.mutationID] {
            #expect(requests[request.mutationID]?.baseRevision == request.baseRevision)
            #expect(requests[request.mutationID]?.payload == request.payload)
            return receipt
        }
        let key = "\(request.kind.rawValue):\(request.entityID)"
        let previous = current[key]
        let reply: MutationReply
        if (previous?.revision ?? 0) != request.baseRevision || (previous?.deleted == true && !request.deleted) {
            reply = .init(status: "conflict", revision: previous?.revision ?? 0, payload: previous?.payload, deleted: previous?.deleted ?? true)
        } else {
            let change = RemoteChange(revision: Int64(changes.count + 1), kind: request.kind, entityID: request.entityID, payload: request.payload, deleted: request.deleted)
            changes.append(change); current[key] = change
            reply = .init(status: "applied", revision: change.revision, payload: change.payload, deleted: change.deleted)
        }
        receipts[request.mutationID] = reply; requests[request.mutationID] = request
        if loseNextResponse { loseNextResponse = false; throw URLError(.networkConnectionLost) }
        return reply
    }
    func pull(after revision: Int64, limit: Int) async throws -> [RemoteChange] { Array(changes.filter { $0.revision > revision }.prefix(limit)) }
}
