import SwiftData
import SwiftUI

struct PhoneRootView: View {
    @Bindable var app: AppController
    @Bindable var store: WorkoutStore
    let sessions: SessionStore
    let activity: WorkoutActivityCoordinator
    @Query(sort: \WorkoutTemplate.name) private var workouts: [WorkoutTemplate]
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var history: [WorkoutSession]
    @State private var search = ""
    @State private var openSession: WorkoutSession?
    var body: some View {
        TabView {
            Tab("Treinos", systemImage: "figure.strengthtraining.traditional") {
                NavigationStack {
                    List {
                        if let current = sessions.activeSession {
                            Section("Em andamento") {
                                Button { openSession = current } label: {
                                    Label("Retomar \(current.name)", systemImage: "play.circle.fill")
                                }
                                .accessibilityIdentifier("resume-session")
                            }
                        }
                        if app.userID == nil {
                            Section { NavigationLink("Entrar para receber seus treinos") { AccountView(app: app) } }
                        }
                        ForEach(filteredWorkouts) { workout in
                            NavigationLink {
                                WorkoutPrescriptionView(workout: workout) {
                                    openSession = sessions.start(workout)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(workout.name).font(.headline)
                                    Text(workout.program?.name ?? "Modelos avulsos").font(.caption).foregroundStyle(.secondary)
                                    Text("\(workout.items.count) exercícios · \(workout.totalSetCount) séries")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                            .accessibilityIdentifier("workout-\(workout.id.uuidString)")
                        }
                    }
                    .overlay {
                        if filteredWorkouts.isEmpty && sessions.activeSession == nil && app.userID != nil {
                            ContentUnavailableView(search.isEmpty ? "Seus treinos aparecem aqui" : "Nenhum treino encontrado",
                                systemImage: "list.bullet.rectangle", description: Text("Crie seus modelos no Mac e sincronize os dois aparelhos."))
                        }
                    }
                    .searchable(text: $search, prompt: "Buscar treinos")
                    .navigationTitle("Treinos")
                    .toolbar {
                        if let sync = app.sync {
                            Button { Task { await sync.sync() } } label: {
                                Label("Sincronizar", systemImage: "arrow.trianglehead.2.clockwise")
                            }.disabled(sync.isSyncing)
                        }
                    }
                    .refreshable { await app.sync?.sync() }
                }
            }
            Tab("Histórico", systemImage: "clock.arrow.circlepath") {
                SessionHistoryView { openSession = $0 }
            }
            Tab("Ajustes", systemImage: "gearshape") {
                NavigationStack { PhoneSettingsView(app: app, activity: activity) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.saveError {
                VStack(alignment: .leading) {
                    Text("Alterações ainda não salvas").font(.callout.bold())
                    Text(error).font(.caption)
                    Button("Tentar novamente") { store.save() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
            }
        }
        .sheet(item: $openSession) { session in
            NavigationStack {
                SessionEditorView(session: session, sessions: sessions, activity: activity, app: app)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { openSession = nil } } }
            }
        }
        .sheet(isPresented: Binding(get: { app.recoveryMode && openSession == nil }, set: { if !$0 { app.recoveryMode = false } })) {
            NavigationStack { AccountView(app: app) }
        }
        .alert("Não foi possível concluir", isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button("OK") { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
        .task { openRequestedSession() }
        .onChange(of: app.requestedSessionID) { _, _ in openRequestedSession() }
        .onChange(of: app.recoveryMode) { _, recovering in if recovering { openSession = nil } }
    }
    private var filteredWorkouts: [WorkoutTemplate] {
        workouts.filter { !$0.isArchived && WorkoutRules.matches(search, in: [$0.name, $0.program?.name ?? "", $0.muscleGroups]) }
    }
    private func openRequestedSession() {
        if let id = app.requestedSessionID, let session = history.first(where: { $0.id == id }) {
            openSession = session; app.requestedSessionID = nil
        }
    }
}

private struct WorkoutPrescriptionView: View {
    let workout: WorkoutTemplate
    let start: () -> Void
    var body: some View {
        List {
            Section {
                if !workout.notes.isEmpty { Text(workout.notes) }
                Button("Iniciar treino", systemImage: "play.fill", action: start)
                    .buttonStyle(.borderedProminent).disabled(workout.items.isEmpty)
            }
            ForEach(workout.orderedItems) { item in
                Section(item.exercise?.name ?? "Exercício") {
                    if !item.notes.isEmpty { Text(item.notes).font(.callout).foregroundStyle(.secondary) }
                    ForEach(item.orderedSets) { set in
                        HStack {
                            SetGlyph(kind: set.kind)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(item.number(for: set).map(String.init) ?? "—") · \(set.kind.label)")
                                Text("\(set.reps.isEmpty ? item.repRange : set.reps) reps · \(set.load.isEmpty ? "—" : set.load) kg")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(WorkoutRules.restText(set.effectiveRestSeconds)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }.navigationTitle(workout.name)
    }
}

private struct PhoneSettingsView: View {
    @Bindable var app: AppController
    let activity: WorkoutActivityCoordinator
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("restNotifications") private var notifications = false
    var body: some View {
        Form {
            Section {
                NavigationLink { AccountView(app: app) } label: {
                    Label(app.email ?? "Conta e sincronização", systemImage: "person.crop.circle")
                }
                if let sync = app.sync { Text(sync.status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Treino") {
                Toggle("Avisar quando o descanso terminar", isOn: $notifications)
                    .onChange(of: notifications) { _, enabled in Task { await activity.setNotifications(enabled, app: app) } }
                if !activity.notificationStatus.isEmpty { Text(activity.notificationStatus).font(.caption).foregroundStyle(.secondary) }
                Text("A atividade ao vivo acompanha seu treino na tela bloqueada e, nos aparelhos compatíveis, na Dynamic Island.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Aparência") {
                Picker("Aparência", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                LabeledContent("Idioma", value: "Português (Brasil)")
                LabeledContent("Carga", value: "kg")
                Text("Seus treinos ficam disponíveis neste iPhone sem conexão depois de recebidos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Ajustes")
    }
}
