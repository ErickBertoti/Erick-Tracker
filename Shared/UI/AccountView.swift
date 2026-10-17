import SwiftData
import SwiftUI

struct AccountView: View {
    @Bindable var app: AppController
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @State private var confirmImport = false
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            if !app.isCloudConfigured {
                Section("Uso local") {
                    Text("A sincronização não foi configurada nesta instalação. Seus dados locais continuam disponíveis.")
                        .foregroundStyle(.secondary)
                }
            } else if app.recoveryMode {
                Section("Nova senha") {
                    SecureField("Senha", text: $password).textContentType(.newPassword)
                    Button("Salvar nova senha") { Task { await app.updatePassword(password); password = "" } }
                        .disabled(password.count < 8 || app.isBusy)
                }
            } else if app.userID != nil {
                Section("Conta") {
                    LabeledContent("Email", value: app.email ?? "Conta conectada")
                    Text("Use esta mesma conta no Mac e no iPhone.").foregroundStyle(.secondary)
                }
                if app.legacyImportCount > 0 {
                    Section {
                        Text("Há \(app.legacyImportCount) registro(s) locais anteriores à conta neste Mac.")
                        Button("Vincular dados locais à conta…") { confirmImport = true }.disabled(app.sync?.isSyncing == true)
                    }
                }
                if let sync = app.sync { SyncStatusSection(engine: sync) }
                Section {
                    Button("Sair da conta…", role: .destructive) { confirmSignOut = true }
                } footer: { Text("Alterações pendentes continuam guardadas neste aparelho para a próxima entrada nesta conta.") }
            } else {
                Section(createAccount ? "Criar conta" : "Entrar na conta") {
                    TextField("Email", text: $email).textContentType(.emailAddress)
                    SecureField("Senha", text: $password).textContentType(createAccount ? .newPassword : .password)
                    Button(createAccount ? "Criar conta" : "Entrar") {
                        Task { await app.signIn(email: email, password: password, create: createAccount); password = "" }
                    }.buttonStyle(.borderedProminent).disabled(app.isBusy || email.isEmpty || password.count < (createAccount ? 8 : 1))
                    Toggle("Criar uma nova conta", isOn: $createAccount)
                    Button("Esqueci minha senha") { Task { await app.resetPassword(email: email) } }
                        .disabled(app.isBusy || email.isEmpty)
                }
                Section {
                    Text("Entre para receber seus treinos e sincronizar o histórico. Depois da primeira sincronização, o treino continua disponível sem internet.")
                        .foregroundStyle(.secondary)
                }
            }
            if app.isBusy { ProgressView() }
            if let error = app.authError { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if let message = app.authMessage { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Conta e sincronização")
        .confirmationDialog("Vincular dados locais?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Vincular à conta \(app.email ?? "atual")") { app.claimLegacyData() }
        } message: { Text("Os identificadores e relacionamentos serão mantidos. Os dados passarão a ser sincronizados com esta conta.") }
        .confirmationDialog("Sair desta conta?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sair", role: .destructive) { Task { await app.signOut() } }
        } message: { Text("Os dados desta conta ficarão ocultos. Séries e alterações pendentes continuam salvas neste aparelho.") }
    }
}

struct SyncStatusSection: View {
    @Bindable var engine: SyncEngine
    @Query(sort: \SyncConflict.createdAt) private var conflicts: [SyncConflict]
    @Query private var pending: [PendingMutation]
    var body: some View {
        Section("Sincronização") {
            Label(engine.status, systemImage: engine.isSyncing ? "arrow.trianglehead.2.clockwise" : "checkmark.icloud")
            if !pending.isEmpty { Text("\(pending.count) alteração(ões) salva(s) neste aparelho aguardando envio.").font(.caption).foregroundStyle(.secondary) }
            if let date = engine.lastSyncAt { LabeledContent("Última sincronização") { Text(date, style: .relative) } }
            if let error = engine.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Sincronizar agora") { Task { await engine.sync() } }.disabled(engine.isSyncing)
        }
        if !conflicts.isEmpty {
            Section("Resolver alterações simultâneas") {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conflictTitle(conflict)).font(.headline)
                        Text(conflict.remotePayload == nil ? "O registro foi excluído na nuvem. Sua versão local está preservada." : "Há uma versão diferente na nuvem. Escolha qual preservar.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Comparar versões") {
                            Text("Neste aparelho").font(.caption.bold())
                            Text(pretty(conflict.localPayload, kind: conflict.kindRaw)).font(.caption.monospaced()).textSelection(.enabled)
                            Text("Na nuvem").font(.caption.bold())
                            Text(pretty(conflict.remotePayload, kind: conflict.kindRaw)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Button("Usar versão da nuvem") { engine.resolve(conflict, choosing: .remote) }
                        if conflict.remotePayload != nil || conflict.kindRaw == EntityKind.workout.rawValue {
                            Button(conflict.remotePayload == nil ? "Salvar como novo treino" : "Usar versão deste aparelho") { engine.resolve(conflict, choosing: .local) }
                        }
                        if conflict.kindRaw == EntityKind.workout.rawValue, conflict.localPayload != nil, conflict.remotePayload != nil {
                            Button("Manter ambos os treinos") { engine.resolve(conflict, choosing: .both) }
                        }
                        if conflict.kindRaw == EntityKind.exercise.rawValue, conflict.remotePayload != nil {
                            Button("Arquivar exercício em vez de apagar") { engine.resolve(conflict, choosing: .archiveExercise) }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private func conflictTitle(_ conflict: SyncConflict) -> String {
        guard let data = conflict.localPayload ?? conflict.remotePayload,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Registro excluído" }
        return value["name"] as? String ?? "Alteração simultânea"
    }
    private func pretty(_ data: Data?, kind: String) -> String {
        guard let data else { return "Excluído" }
        switch EntityKind(rawValue: kind) {
        case .workout:
            guard let w = try? SnapshotCodec.decode(WorkoutSnapshot.self, from: data) else { return "Versão preservada" }
            return ([w.name, w.notes] + w.items.map { item in
                item.exerciseName + ": " + item.sets.map { "\($0.kind.label), \($0.reps) reps, \($0.load) kg" }.joined(separator: "; ")
            }).filter { !$0.isEmpty }.joined(separator: "\n")
        case .exercise:
            guard let e = try? SnapshotCodec.decode(ExerciseSnapshot.self, from: data) else { return "Versão preservada" }
            return [e.name, e.primaryMuscle, e.equipment, e.notes, e.isArchived ? "Arquivado" : "Ativo"].filter { !$0.isEmpty }.joined(separator: "\n")
        case .program: return (try? SnapshotCodec.decode(ProgramSnapshot.self, from: data).name) ?? "Programa preservado"
        case .session:
            guard let s = try? SnapshotCodec.decode(SessionSnapshot.self, from: data) else { return "Sessão preservada" }
            return ([s.name, s.notes] + s.exercises.map { e in
                e.name + ": " + e.sets.flatMap(\.segments).map { "\($0.reps.map(String.init) ?? "—") reps × \($0.loadKg ?? "—") kg" }.joined(separator: "; ")
            }).filter { !$0.isEmpty }.joined(separator: "\n")
        case nil: return "Versão preservada"
        }
    }
}
