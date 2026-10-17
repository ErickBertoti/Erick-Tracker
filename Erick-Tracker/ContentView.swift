import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkoutStore
    var account: AppController?
    @State private var showingAccount = false
    @Query(sort: \Program.position) private var programs: [Program]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutTemplate.updatedAt, order: .reverse) private var workouts: [WorkoutTemplate]
    @State private var navigation = WorkspaceState()
    @State private var editorSheet: EditorSheet?
    @State private var deletion: DeletionRequest?
    @State private var addingExercise = false
    @State private var pendingExerciseWorkoutID: UUID?
    @FocusState private var searchFocused: Bool

    init(store: WorkoutStore, account: AppController? = nil, navigation: WorkspaceState? = nil) {
        self.store = store; self.account = account
        _navigation = State(initialValue: navigation ?? WorkspaceState())
    }

    private var editingWorkout: WorkoutTemplate? { workouts.first { $0.id == navigation.editingWorkoutID } }
    private var selectedWorkout: WorkoutTemplate? { workouts.first { $0.id == navigation.selectedWorkoutID } }
    private var selectedExercise: Exercise? { exercises.first { $0.id == navigation.selectedExerciseID } }
    private var selectedItem: WorkoutItem? { editingWorkout?.items.first { $0.id == navigation.selectedItemID } }
    private var selectedProgram: Program? {
        if case .program(let id) = navigation.destination { return programs.first { $0.id == id } }
        return nil
    }
    private var isHome: Bool { navigation.destination == .home && editingWorkout == nil }
    private var title: String {
        if let workout = editingWorkout { return workout.name }
        switch navigation.destination {
        case .home: return "Início"
        case .workouts: return "Treinos"
        case .exercises: return "Exercícios"
        case .history: return "Histórico"
        case .program: return selectedProgram?.name ?? "Treinos"
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(title)
                .toolbar { toolbar }
                .inspector(isPresented: Binding(get: { navigation.inspectorVisible && !isHome && navigation.destination != .history }, set: { navigation.inspectorVisible = $0 })) {
                    inspector.inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let message = store.saveError {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Não foi possível salvar as alterações", systemImage: "exclamationmark.triangle")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Button("Tentar novamente") { store.save() }
                            }
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(12).background(.regularMaterial)
                    }
                }
        }
        .sheet(isPresented: $showingAccount) {
            if let account { AccountView(app: account).frame(width: 580, height: 620) }
        }
        .onChange(of: account?.recoveryMode) { _, recovering in if recovering == true { showingAccount = true } }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1024, minHeight: 700)
        .focusedSceneValue(\.trackerCommands, commandActions)
        .sheet(item: $editorSheet, onDismiss: { pendingExerciseWorkoutID = nil }) { route in
            switch route {
            case .program(let program):
                NameEditorSheet(title: program == nil ? "Novo programa" : "Renomear programa", name: program?.name ?? "") { name in
                    if let program { store.renameProgram(program, name: name) }
                    else if let created = store.createProgram(name: name, position: (programs.map(\.position).max() ?? -1) + 1) {
                        navigation.navigate(to: .program(created.id))
                    }
                }
            case .workout(let program):
                NameEditorSheet(title: "Novo treino") { name in
                    if let created = store.createWorkout(name: name, program: program) {
                        navigation.showArchivedWorkouts = false; navigation.open(created)
                    }
                }
            case .exercise(let exercise):
                ExerciseEditorSheet(exercise: exercise, store: store) { saved in
                    if let workout = workouts.first(where: { $0.id == pendingExerciseWorkoutID }) {
                        navigation.selectedItemID = store.addExercise(saved, to: workout).id
                    } else {
                        navigation.navigate(to: .exercises); navigation.showArchivedExercises = false
                        navigation.muscleFilter = ""; navigation.equipmentFilter = ""; navigation.kindFilter = ""
                        navigation.selectedExerciseID = saved.id; navigation.inspectorVisible = true
                    }
                }
            }
        }
        .confirmationDialog(deletion?.needsArchive == true ? "Este exercício está em uso" : "Apagar “\(deletion?.name ?? "")”?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible, presenting: deletion) { request in
            if request.needsArchive {
                Button("Arquivar exercício") {
                    if case .exercise(let exercise) = request { store.setArchived(exercise, true); navigation.selectedExerciseID = nil }
                }
            } else {
                Button("Apagar", role: .destructive) { performDeletion(request) }
            }
            Button("Cancelar", role: .cancel) { }
        } message: { Text($0.message) }
        .alert("Não foi possível concluir a ação", isPresented: Binding(get: { store.operationError != nil }, set: { if !$0 { store.operationError = nil } })) {
            Button("OK") { store.operationError = nil }
        } message: { Text(store.operationError ?? "") }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { navigation.destination }, set: { navigation.navigate(to: $0) })) {
            Section {
                Label("Início", systemImage: "house").tag(WorkspaceDestination.home)
                Label("Treinos", systemImage: "list.bullet.rectangle").tag(WorkspaceDestination.workouts)
                Label("Exercícios", systemImage: "figure.strengthtraining.traditional").tag(WorkspaceDestination.exercises)
                Label("Histórico", systemImage: "clock.arrow.circlepath").tag(WorkspaceDestination.history)
            }
            Section {
                ForEach(programs) { program in
                    HStack {
                        Label(program.name, systemImage: "folder").lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(program.workouts.filter { !$0.isArchived }.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(WorkspaceDestination.program(program.id))
                    .contextMenu {
                        Button("Novo treino neste programa…") { editorSheet = .workout(program) }
                        Button("Renomear…") { editorSheet = .program(program) }
                        Divider()
                        Button("Apagar programa…", role: .destructive) { deletion = .program(program) }
                    }
                }
                Button { editorSheet = .program(nil) } label: { Label("Novo programa", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } header: { Text("Programas") }
        }
        .listStyle(.sidebar)
        .navigationTitle("Erick Tracker")
        .navigationSplitViewColumnWidth(min: 184, ideal: 216, max: 270)
        .safeAreaInset(edge: .bottom, spacing: 0) { SaveStatusView(store: store) }
    }

    @ViewBuilder private var detail: some View {
        if let workout = editingWorkout {
            WorkoutEditorView(workout: workout, store: store, navigation: navigation) { addingExercise = true }
        } else if navigation.destination == .home {
            HomeView(workouts: workouts, exerciseCount: exercises.filter { !$0.isArchived }.count,
                programCount: programs.count, newWorkout: { editorSheet = .workout(nil) },
                newExercise: { editorSheet = .exercise(nil) }, newProgram: { editorSheet = .program(nil) },
                openWorkout: { navigation.open($0) })
        } else if navigation.destination == .history {
            SessionHistoryView()
        } else {
            libraries
                .searchable(text: $navigation.search, placement: .toolbar,
                            prompt: navigation.destination == .exercises ? "Buscar exercícios" : "Buscar treinos")
                .searchFocused($searchFocused)
        }
    }
    @ViewBuilder private var libraries: some View {
        if navigation.destination == .exercises {
            ExerciseLibraryView(exercises: exercises, navigation: navigation, store: store,
                edit: { editorSheet = .exercise($0) }, requestDelete: { deletion = .exercise($0) })
        } else {
            WorkoutLibraryView(workouts: workouts, navigation: navigation, store: store,
                newWorkout: { editorSheet = .workout(selectedProgram) }, requestDelete: { deletion = .workout($0) })
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if editingWorkout != nil {
                Button {
                    navigation.editingWorkoutID = nil; navigation.selectedItemID = nil
                } label: { Label("Voltar para treinos", systemImage: "chevron.left") }
                .help("Voltar para treinos")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let account {
                Button { showingAccount = true } label: { Label(account.sync?.status ?? "Conta", systemImage: "person.crop.circle") }
            }
            if navigation.destination != .history {
            Button(action: primaryAction) { Label(primaryTitle, systemImage: "plus") }
                .help(primaryTitle + " (⌘N)")
                .popover(isPresented: $addingExercise) {
                    AddExercisePopover(exercises: exercises) { exercise in
                        if let workout = editingWorkout { navigation.selectedItemID = store.addExercise(exercise, to: workout).id }
                        addingExercise = false
                    } newExercise: {
                        pendingExerciseWorkoutID = editingWorkout?.id
                        addingExercise = false; editorSheet = .exercise(nil)
                    }
                }
            }
            if !isHome && navigation.destination != .history {
                Button { navigation.inspectorVisible.toggle() } label: { Label("Mostrar inspetor", systemImage: "sidebar.right") }
                    .help("Mostrar ou ocultar inspetor (⌥⌘I)")
            }
            Menu {
                Button("Novo programa…") { editorSheet = .program(nil) }
                if let program = selectedProgram {
                    Button("Renomear programa…") { editorSheet = .program(program) }
                    Button("Apagar programa…", role: .destructive) { deletion = .program(program) }
                }
                if let workout = editingWorkout ?? selectedWorkout, navigation.destination != .exercises && !isHome {
                    Divider()
                    Button("Duplicar treino") { navigation.open(store.duplicateWorkout(workout)) }
                    Button(workout.isArchived ? "Restaurar treino" : "Arquivar treino") { store.setArchived(workout, !workout.isArchived) }
                    Button("Apagar treino…", role: .destructive) { deletion = .workout(workout) }
                }
                Divider()
                SettingsLink { Text("Ajustes…") }
            } label: { Label("Mais ações", systemImage: "ellipsis") }.help("Mais ações")
        }
    }

    @ViewBuilder private var inspector: some View {
        if let item = selectedItem {
            WorkoutItemInspector(item: item, store: store, openLibrary: {
                let id = item.exercise?.id
                navigation.navigate(to: .exercises); navigation.selectedExerciseID = id
            }, duplicate: { navigation.selectedItemID = store.duplicateItem(item)?.id }, remove: {
                navigation.selectedItemID = nil; store.removeItem(item)
            })
        } else if navigation.destination == .exercises, let exercise = selectedExercise {
            ExerciseInspector(exercise: exercise, workouts: workouts, store: store,
                edit: { editorSheet = .exercise(exercise) }, openWorkout: { navigation.open($0) },
                delete: { deletion = .exercise(exercise) })
        } else if navigation.destination != .exercises, let workout = editingWorkout ?? selectedWorkout {
            WorkoutInspector(workout: workout, programs: programs, store: store,
                open: { navigation.open(workout) }, duplicate: { navigation.open(store.duplicateWorkout(workout)) },
                delete: { deletion = .workout(workout) })
        } else {
            ContentUnavailableView(navigation.destination == .exercises ? "Selecione um exercício" : "Selecione um treino",
                systemImage: navigation.destination == .exercises ? "figure.strengthtraining.traditional" : "list.bullet.rectangle",
                description: Text("Os detalhes aparecem aqui."))
        }
    }

    private var primaryTitle: String {
        if editingWorkout != nil { return "Adicionar exercício" }
        return navigation.destination == .exercises ? "Novo exercício" : "Novo treino"
    }
    private func primaryAction() {
        if editingWorkout != nil { addingExercise = true }
        else if navigation.destination == .exercises { editorSheet = .exercise(nil) }
        else { editorSheet = .workout(selectedProgram) }
    }
    private func performDeletion(_ request: DeletionRequest) {
        switch request {
        case .program(let program):
            if selectedProgram?.id == program.id { navigation.navigate(to: .workouts) }
            store.deleteProgram(program)
        case .exercise(let exercise):
            navigation.selectedExerciseID = nil; store.deleteExercise(exercise)
        case .workout(let workout):
            if navigation.editingWorkoutID == workout.id { navigation.editingWorkoutID = nil; navigation.selectedItemID = nil }
            if navigation.selectedWorkoutID == workout.id { navigation.selectedWorkoutID = nil }
            store.deleteWorkout(workout)
        }
    }

    private var commandActions: WorkspaceCommandActions {
        let item = selectedItem
        let ordered = editingWorkout?.orderedItems ?? []
        let index = ordered.firstIndex { $0.id == item?.id }
        return WorkspaceCommandActions(primaryTitle: primaryTitle, primary: primaryAction,
            newWorkout: { editorSheet = .workout(selectedProgram) }, newProgram: { editorSheet = .program(nil) },
            search: {
                if editingWorkout != nil { addingExercise = true }
                else {
                    if isHome { navigation.navigate(to: .workouts) }
                    searchFocused = true
                }
            }, toggleInspector: isHome ? nil : { navigation.inspectorVisible.toggle() },
            duplicate: duplicateAction, delete: deleteAction,
            addExercise: editingWorkout == nil ? nil : { addingExercise = true },
            addSet: item.map { selected in { store.addSet(to: selected) } },
            moveUp: index.flatMap { $0 > 0 ? item.map { selected in { store.moveItem(selected, by: -1) } } : nil },
            moveDown: index.flatMap { $0 < ordered.count - 1 ? item.map { selected in { store.moveItem(selected, by: 1) } } : nil },
            navigate: { navigation.navigate(to: $0) })
    }
    private var duplicateAction: (() -> Void)? {
        if let item = selectedItem { return { navigation.selectedItemID = store.duplicateItem(item)?.id } }
        if navigation.destination == .exercises, let exercise = selectedExercise {
            return { navigation.selectedExerciseID = store.duplicateExercise(exercise)?.id }
        }
        if !isHome && navigation.destination != .exercises, let workout = editingWorkout ?? selectedWorkout {
            return { navigation.open(store.duplicateWorkout(workout)) }
        }
        return nil
    }
    private var deleteAction: (() -> Void)? {
        if let item = selectedItem { return { navigation.selectedItemID = nil; store.removeItem(item) } }
        if navigation.destination == .exercises, let exercise = selectedExercise { return { deletion = .exercise(exercise) } }
        if !isHome && navigation.destination != .exercises, let workout = editingWorkout ?? selectedWorkout { return { deletion = .workout(workout) } }
        return nil
    }
}

#Preview {
    let container = try! PersistenceController.makeContainer(inMemory: true)
    ContentView(store: WorkoutStore(context: container.mainContext)).modelContainer(container)
}
