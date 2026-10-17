import SwiftUI

struct WorkoutLibraryView: View {
    let workouts: [WorkoutTemplate]
    @Bindable var navigation: WorkspaceState
    let store: WorkoutStore
    let newWorkout: () -> Void
    let requestDelete: (WorkoutTemplate) -> Void

    private var visible: [WorkoutTemplate] {
        workouts.filter { workout in
            let programMatches: Bool
            if case .program(let id) = navigation.destination { programMatches = workout.program?.id == id }
            else { programMatches = true }
            return programMatches && workout.isArchived == navigation.showArchivedWorkouts
                && WorkoutRules.matches(navigation.search, in: [workout.name, workout.program?.name ?? "", workout.muscleGroups])
        }.sorted {
            if $0.program?.position != $1.program?.position { return ($0.program?.position ?? Int.max) < ($1.program?.position ?? Int.max) }
            if $0.program?.id != $1.program?.id { return ($0.program?.name ?? "").localizedStandardCompare($1.program?.name ?? "") == .orderedAscending }
            return $0.position == $1.position ? $0.createdAt < $1.createdAt : $0.position < $1.position
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Modelos", selection: $navigation.showArchivedWorkouts) {
                    Text("Ativos").tag(false)
                    Text("Arquivados").tag(true)
                }.pickerStyle(.segmented).fixedSize()
                Spacer()
                Text(WorkoutRules.count(visible.count, singular: "modelo", plural: "modelos")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if visible.isEmpty {
                EmptyWorkspace(title: emptyTitle, icon: "list.bullet.rectangle",
                    message: navigation.search.isEmpty ? "Monte um modelo com os exercícios e as séries que você deseja planejar." : "Tente outro termo ou limpe a busca.",
                    actionTitle: navigation.search.isEmpty ? "Novo treino" : "Limpar busca") {
                    if navigation.search.isEmpty { newWorkout() } else { navigation.search = "" }
                }
            } else {
                Table(visible, selection: $navigation.selectedWorkoutID) {
                    TableColumn("Nome") { workout in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workout.name).fontWeight(.medium).lineLimit(1)
                            if !workout.muscleGroups.isEmpty {
                                Text(workout.muscleGroups).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 4)
                    }.width(min: 140, ideal: 240)
                    TableColumn("Programa") { Text($0.program?.name ?? "Modelos avulsos").lineLimit(1) }
                        .width(min: 80, ideal: 130)
                    TableColumn("Exerc.") { Text($0.items.count, format: .number).monospacedDigit() }.width(48)
                    TableColumn("Séries") { Text($0.totalSetCount, format: .number).monospacedDigit() }.width(48)
                    TableColumn("Edição") { Text($0.updatedAt, format: .dateTime.day().month(.abbreviated)).font(.caption) }.width(70)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let workout = workouts.first(where: { $0.id == id }) {
                        Button("Abrir no editor") { navigation.open(workout) }
                        Button("Duplicar") { navigation.open(store.duplicateWorkout(workout)) }
                        Button(workout.isArchived ? "Restaurar" : "Arquivar") { store.setArchived(workout, !workout.isArchived) }
                        Divider()
                        Button("Apagar…", role: .destructive) { requestDelete(workout) }
                    }
                } primaryAction: { ids in
                    if let workout = workouts.first(where: { $0.id == ids.first }) { navigation.open(workout) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button(action: newWorkout) { Image(systemName: "plus") }.help("Novo treino (⌘N)")
                Button {
                    if let workout = workouts.first(where: { $0.id == navigation.selectedWorkoutID }) { requestDelete(workout) }
                } label: { Image(systemName: "minus") }.disabled(navigation.selectedWorkoutID == nil).help("Apagar treino")
                Divider().frame(height: 14)
                Text("Clique duplo ou ↩ para abrir no editor").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.buttonStyle(.borderless).padding(12)
        }
        .onChange(of: navigation.showArchivedWorkouts) { _, _ in navigation.selectedWorkoutID = nil }
    }
    private var emptyTitle: String {
        if !navigation.search.isEmpty { return "Nenhum treino encontrado" }
        return navigation.showArchivedWorkouts ? "Nenhum treino arquivado" : "Seus modelos de treino"
    }
}

struct ExerciseLibraryView: View {
    let exercises: [Exercise]
    @Bindable var navigation: WorkspaceState
    let store: WorkoutStore
    let edit: (Exercise?) -> Void
    let requestDelete: (Exercise) -> Void

    private var visible: [Exercise] {
        exercises.filter { exercise in
            exercise.isArchived == navigation.showArchivedExercises
                && (navigation.muscleFilter.isEmpty || exercise.primaryMuscle == navigation.muscleFilter)
                && (navigation.equipmentFilter.isEmpty || exercise.equipment == navigation.equipmentFilter)
                && (navigation.kindFilter.isEmpty || exercise.kindRawValue == navigation.kindFilter)
                && WorkoutRules.matches(navigation.search, in: [exercise.name, exercise.primaryMuscle,
                    exercise.secondaryMuscles, exercise.equipment, exercise.movementPattern])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func options(_ keyPath: KeyPath<Exercise, String>) -> [String] {
        Array(Set(exercises.filter { $0.isArchived == navigation.showArchivedExercises }.map { $0[keyPath: keyPath] }.filter { !$0.isEmpty })).sorted()
    }
    private var hasFilters: Bool {
        !navigation.search.isEmpty || !navigation.muscleFilter.isEmpty || !navigation.equipmentFilter.isEmpty || !navigation.kindFilter.isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Biblioteca", selection: $navigation.showArchivedExercises) {
                        Text("Ativos").tag(false); Text("Arquivados").tag(true)
                    }.pickerStyle(.segmented).fixedSize()
                    Spacer()
                    Text(WorkoutRules.count(visible.count, singular: "exercício", plural: "exercícios")).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Picker("Grupo", selection: $navigation.muscleFilter) {
                        Text("Todos").tag("")
                        ForEach(options(\.primaryMuscle), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Equipamento", selection: $navigation.equipmentFilter) {
                        Text("Todos").tag("")
                        ForEach(options(\.equipment), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Tipo", selection: $navigation.kindFilter) {
                        Text("Todos").tag("")
                        ForEach(ExerciseKind.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }.controlSize(.small)
            }.padding(12)
            Divider()
            if visible.isEmpty {
                EmptyWorkspace(title: hasFilters ? "Nenhum exercício encontrado" : "Sua biblioteca começa aqui",
                    icon: "figure.strengthtraining.traditional",
                    message: hasFilters ? "Tente outra busca ou remova os filtros." : "Cadastre os movimentos que você usa. Depois, adicione-os aos seus treinos.",
                    actionTitle: hasFilters ? "Limpar filtros" : "Novo exercício") {
                    if hasFilters { clearFilters() } else { edit(nil) }
                }
            } else {
                Table(visible, selection: $navigation.selectedExerciseID) {
                    TableColumn("Nome") { exercise in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name).fontWeight(.medium).lineLimit(1)
                            if !exercise.secondaryMuscles.isEmpty {
                                Text(exercise.secondaryMuscles).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 4)
                    }.width(min: 140, ideal: 230)
                    TableColumn("Principal") { Text($0.primaryMuscle.isEmpty ? "—" : $0.primaryMuscle).lineLimit(1) }
                        .width(min: 80, ideal: 130)
                    TableColumn("Equipamento") { Text($0.equipment.isEmpty ? "—" : $0.equipment).lineLimit(1) }
                        .width(min: 90, ideal: 140)
                    TableColumn("Tipo") { Text($0.kind.label).font(.caption) }.width(78)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let exercise = exercises.first(where: { $0.id == ids.first }) {
                        Button("Editar…") { edit(exercise) }
                        Button("Duplicar") {
                            if let copy = store.duplicateExercise(exercise) { navigation.selectedExerciseID = copy.id }
                        }
                        Button(exercise.isArchived ? "Restaurar" : "Arquivar") { store.setArchived(exercise, !exercise.isArchived) }
                        Divider()
                        Button("Apagar…", role: .destructive) { requestDelete(exercise) }
                    }
                } primaryAction: { ids in
                    if let exercise = exercises.first(where: { $0.id == ids.first }) { edit(exercise) }
                }
            }
            Divider()
            HStack {
                Button { edit(nil) } label: { Label("Novo exercício", systemImage: "plus") }
                Spacer()
                Text("Clique duplo para editar").font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).padding(12)
        }
        .onChange(of: navigation.showArchivedExercises) { _, _ in
            navigation.selectedExerciseID = nil; clearFilters()
        }
    }
    private func clearFilters() {
        navigation.search = ""; navigation.muscleFilter = ""
        navigation.equipmentFilter = ""; navigation.kindFilter = ""
    }
}
