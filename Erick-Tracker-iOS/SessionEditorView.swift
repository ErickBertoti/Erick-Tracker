import Observation
import SwiftData
import SwiftUI

@MainActor @Observable private final class SessionDrafts {
    struct Value { var reps: String; var load: String }
    var values: [UUID: Value] = [:]
    func value(_ p: SetLogSegment) -> Value {
        values[p.id] ?? .init(reps: p.reps.map(String.init) ?? "", load: p.loadKg?.replacingOccurrences(of: ".", with: ",") ?? "")
    }
    func commit(using sessions: SessionStore) -> Bool {
        let all = (try? sessions.context.fetch(FetchDescriptor<SetLogSegment>())) ?? []
        for (id, value) in values {
            if let segment = all.first(where: { $0.id == id }),
               !sessions.update(segment, reps: value.reps, load: value.load) { return false }
        }
        values.removeAll(); return true
    }
}

struct SessionEditorView: View {
    @Bindable var session: WorkoutSession
    let sessions: SessionStore
    let activity: WorkoutActivityCoordinator
    let app: AppController
    @State private var drafts = SessionDrafts()
    @State private var picker: SessionExercisePickerMode?
    @State private var finishConfirmation = false
    @State private var cancelConfirmation = false
    @FocusState private var activeField: String?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            Section {
                HStack {
                    Label(sessionStatus(session.status), systemImage: session.isActive ? "record.circle" : "checkmark.circle")
                    Spacer()
                    Text("\(session.completedSetCount)/\(session.totalSetCount) séries").monospacedDigit()
                }
                if session.isActive { SessionClockView(session: session, sessions: sessions) }
                if session.isActive {
                    HStack {
                        Button(session.status == .paused ? "Retomar" : "Pausar", systemImage: session.status == .paused ? "play.fill" : "pause.fill") {
                            guard drafts.commit(using: sessions) else { return }
                            if session.status == .paused { sessions.resume(session) } else { sessions.pause(session) }
                        }.buttonStyle(.bordered)
                        Button("Concluir", systemImage: "checkmark") {
                            if drafts.commit(using: sessions) { finishConfirmation = true }
                        }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("As correções atualizam o realizado. A prescrição original fica preservada.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(session.orderedExercises) { exercise in
                Section {
                    if exercise.name != exercise.prescribedName && !exercise.prescribedName.isEmpty {
                        Text("Planejado: \(exercise.prescribedName)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(exercise.orderedSets) { set in
                        LoggedSetEditor(set: set, sessions: sessions, drafts: drafts, focus: $activeField)
                    }
                    Button("Adicionar série", systemImage: "plus") {
                        if drafts.commit(using: sessions) { sessions.addSet(to: exercise) }
                    }
                } header: {
                    HStack {
                        Text(exercise.name)
                        Spacer()
                        Menu {
                            Button("Trocar exercício") { if drafts.commit(using: sessions) { picker = .replace(exercise.id) } }
                            Button("Mover para cima") { if drafts.commit(using: sessions) { sessions.move(exercise, by: -1) } }
                            Button("Mover para baixo") { if drafts.commit(using: sessions) { sessions.move(exercise, by: 1) } }
                            Button("Remover da sessão", role: .destructive) { if drafts.commit(using: sessions) { sessions.remove(exercise) } }
                        } label: { Label("Ações do exercício", systemImage: "ellipsis.circle") }.labelStyle(.iconOnly)
                    }
                }
            }
            Section {
                Button("Adicionar exercício", systemImage: "plus") {
                    if drafts.commit(using: sessions) { picker = .add }
                }
            }
            Section("Notas da sessão") {
                CommitNotes(value: session.notes) { value in sessions.update(session) { session.notes = value } }
            }
            if session.isActive {
                Section {
                    Button("Mostrar atividade ao vivo", systemImage: "waveform.path") {
                        session.activityDismissed = false; sessions.touch(session); activity.refresh(app: app)
                    }
                    Button("Cancelar sessão…", role: .destructive) { cancelConfirmation = true }
                }
            }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("OK") { activeField = nil; _ = drafts.commit(using: sessions) } } }
        .onChange(of: activeField) { old, new in if old != nil && new == nil { _ = drafts.commit(using: sessions) } }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picker) { mode in
            NavigationStack {
                SessionExercisePicker { exercise in
                    switch mode {
                    case .add: sessions.addExercise(exercise, to: session)
                    case .replace(let id): if let e = session.exercises.first(where: { $0.id == id }) { sessions.replace(e, with: exercise) }
                    }
                    picker = nil
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { picker = nil } } }
            }
        }
        .confirmationDialog("Concluir treino?", isPresented: $finishConfirmation, titleVisibility: .visible) {
            Button("Concluir treino") { sessions.finish(session) }
        } message: { Text("Séries ainda pendentes serão marcadas como ignoradas. Você poderá corrigir o registro depois.") }
        .confirmationDialog("Cancelar esta sessão?", isPresented: $cancelConfirmation, titleVisibility: .visible) {
            Button("Cancelar e preservar registros", role: .destructive) {
                if drafts.commit(using: sessions) { sessions.finish(session, cancelled: true) }
            }
        } message: { Text("A sessão ficará no histórico como cancelada, preservando as séries registradas.") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { _ = drafts.commit(using: sessions) } }
        .onDisappear { _ = drafts.commit(using: sessions) }
    }
}

private struct LoggedSetEditor: View {
    @Bindable var set: SetLog
    let sessions: SessionStore
    @Bindable var drafts: SessionDrafts
    let focus: FocusState<String?>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SetGlyph(kind: set.kind)
                Text(set.exercise?.number(for: set).map { "Série \($0)" } ?? "Preparação").font(.headline)
                Spacer()
                Picker("Tipo de série", selection: Binding(get: { set.kind }, set: { value in sessions.update(set) { set.kind = value } })) {
                    ForEach(SetKind.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
            }
            Text("Planejado: \(set.prescribedReps.isEmpty ? "—" : set.prescribedReps) reps · \(set.prescribedLoad.isEmpty ? "—" : set.prescribedLoad) kg · \(set.intensityScaleRaw.uppercased()) \(set.prescribedIntensity.isEmpty ? "—" : set.prescribedIntensity)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(set.orderedSegments) { p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if set.segments.count > 1 { Text("\(p.position + 1)").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Repetições").font(.caption).foregroundStyle(.secondary)
                        TextField("Reps", text: Binding(get: { drafts.value(p).reps }, set: {
                            var d = drafts.value(p); d.reps = $0; drafts.values[p.id] = d
                        })).keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused(focus, equals: p.id.uuidString + "r")
                            .accessibilityLabel("Repetições da etapa \(p.position + 1)")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Carga (kg)").font(.caption).foregroundStyle(.secondary)
                        TextField("Opcional", text: Binding(get: { drafts.value(p).load }, set: {
                            var d = drafts.value(p); d.load = $0; drafts.values[p.id] = d
                        })).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).focused(focus, equals: p.id.uuidString + "l")
                            .accessibilityLabel("Carga em kg da etapa \(p.position + 1)")
                    }
                    if set.segments.count > 1 {
                        Button(role: .destructive) { if drafts.commit(using: sessions) { sessions.remove(p) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remover etapa \(p.position + 1)")
                    }
                }
            }
            Button("Adicionar etapa", systemImage: "plus.circle") {
                if drafts.commit(using: sessions) { sessions.addSegment(to: set) }
            }.font(.caption).buttonStyle(.borderless)
            HStack {
                CommitTextField(set.intensityScaleRaw.uppercased(), value: set.intensity, placeholder: "\(set.intensityScaleRaw.uppercased())") { value in
                    guard WorkoutRules.validIntensity(value) else { sessions.store.operationError = "Informe intensidade entre 0 e 10."; return false }
                    sessions.update(set) { set.intensity = value }; return true
                }.frame(maxWidth: 120)
                CommitTextField("Descanso", value: WorkoutRules.restText(set.restSeconds)) { value in
                    guard let seconds = WorkoutRules.parseRest(value) else { sessions.store.operationError = "Use 2:30 ou segundos inteiros."; return false }
                    sessions.update(set) { set.restSeconds = seconds }; return true
                }
            }
            CommitTextField("Nota da série", value: set.notes, placeholder: "Nota da série") { value in sessions.update(set) { set.notes = value }; return true }
            HStack {
                Button(set.status == .completed ? "Realizada" : "Registrar série", systemImage: set.status == .completed ? "checkmark.circle.fill" : "circle") {
                    focus.wrappedValue = nil
                    if drafts.commit(using: sessions) { sessions.mark(set, as: .completed) }
                }.buttonStyle(.borderedProminent).tint(set.status == .completed ? .green : .teal)
                Menu {
                    Button("Marcar como ignorada") { if drafts.commit(using: sessions) { sessions.mark(set, as: .skipped) } }
                    Button("Voltar para pendente") { if drafts.commit(using: sessions) { sessions.mark(set, as: .pending) } }
                    Button("Remover série", role: .destructive) { if drafts.commit(using: sessions) { sessions.remove(set) } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Mais ações da série")
                if set.status == .skipped { Text("Ignorada").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 7)

    }
}

private struct SessionClockView: View {
    let session: WorkoutSession
    let sessions: SessionStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Duração", value: WorkoutRules.restText(Int(session.elapsed(at: timeline.date))))
                if let end = session.restEndsAt, end > timeline.date {
                    HStack {
                        Label("Descanso", systemImage: "timer")
                        Spacer()
                        Text(timerInterval: (session.restStartedAt ?? timeline.date)...end, countsDown: true, showsHours: false).monospacedDigit().frame(width: 65)
                    }
                    HStack {
                        Button("+30 s") { sessions.setRest(session, seconds: max(0, Int(end.timeIntervalSinceNow)) + 30) }
                        Button("Pular descanso") { sessions.setRest(session, seconds: 0) }
                    }.buttonStyle(.bordered)
                } else if session.status == .paused, let remaining = session.pausedRestSeconds {
                    LabeledContent("Descanso pausado", value: WorkoutRules.restText(Int(remaining)))
                }
            }.monospacedDigit()
        }
    }
}
private enum SessionExercisePickerMode: Identifiable {
    case add, replace(UUID)
    var id: String { switch self { case .add: "add"; case .replace(let id): id.uuidString } }
}
private struct SessionExercisePicker: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var search = ""
    let select: (Exercise) -> Void
    var body: some View {
        List(exercises.filter { !$0.isArchived && WorkoutRules.matches(search, in: [$0.name, $0.equipment, $0.primaryMuscle]) }) { e in
            Button { select(e) } label: {
                VStack(alignment: .leading) { Text(e.name); Text([e.primaryMuscle, e.equipment].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }
        }.searchable(text: $search, prompt: "Buscar exercício").navigationTitle("Escolher exercício")
            .overlay { if exercises.isEmpty { ContentUnavailableView("Biblioteca vazia", systemImage: "dumbbell", description: Text("Cadastre exercícios no Mac e sincronize.")) } }
    }
}
