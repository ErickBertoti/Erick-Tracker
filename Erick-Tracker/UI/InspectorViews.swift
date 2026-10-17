import SwiftUI

struct WorkoutInspector: View {
    let workout: WorkoutTemplate
    let programs: [Program]
    let store: WorkoutStore
    let open: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    var body: some View {
        Form {
            Section("Treino") {
                CommitTextField("Nome do treino", value: workout.name) { store.renameWorkout(workout, name: $0) }
                Picker("Programa", selection: Binding<UUID?>(get: { workout.program?.id }, set: { id in
                    store.assign(workout, to: programs.first { $0.id == id })
                })) {
                    Text("Modelos avulsos").tag(nil as UUID?)
                    ForEach(programs) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Section("Resumo") {
                LabeledContent("Exercícios", value: "\(workout.items.count)")
                LabeledContent("Séries totais", value: "\(workout.totalSetCount)")
                LabeledContent("Séries de trabalho", value: "\(workout.workingSetCount)")
                LabeledContent("Duração estimada", value: "≈ \(workout.estimatedMinutes) min")
            }
            Section("Notas do treino") {
                CommitNotes(value: workout.notes) { value in store.updateWorkout(workout) { workout.notes = value } }
            }
            if !workout.items.isEmpty {
                Section("Ordem dos exercícios") {
                    ForEach(workout.orderedItems) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(item.position + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                            Text(item.exercise?.name ?? "Exercício indisponível")
                            Spacer()
                            Text("\(item.sets.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Abrir no editor", action: open)
                Button("Duplicar", action: duplicate)
                Button(workout.isArchived ? "Restaurar treino" : "Arquivar treino") { store.setArchived(workout, !workout.isArchived) }
                Button("Apagar treino…", role: .destructive, action: delete)
            }
            Section {
                Text("Editado em \(workout.updatedAt.formatted(.dateTime.day().month().year().hour().minute().locale(WorkoutRules.locale)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).id(workout.id)
    }
}

struct WorkoutItemInspector: View {
    let item: WorkoutItem
    let store: WorkoutStore
    let openLibrary: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    var body: some View {
        Form {
            Section {
                Text(item.exercise?.name ?? "Exercício indisponível").font(.title3.weight(.semibold))
                Text(item.exercise?.equipment ?? "").font(.caption).foregroundStyle(.secondary)
                Button("Ver na biblioteca", action: openLibrary)
            }
            Section("Neste treino") {
                LabeledContent("Descanso") {
                    CommitTextField("Descanso padrão", value: WorkoutRules.restText(item.restSeconds)) { store.changeRest($0, item: item) }
                        .frame(width: 80)
                }
                LabeledContent("Repetições") {
                    CommitTextField("Faixa de repetições", value: item.repRange, placeholder: "6–8") { value in
                        store.updateItem(item) { item.repRange = value }; return true
                    }.frame(width: 90)
                }
                Picker("Intensidade", selection: Binding(get: { item.intensityScale }, set: { store.changeScale(of: item, to: $0) })) {
                    ForEach(IntensityScale.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).help("Ao trocar a escala, os valores preenchidos são convertidos por 10 − valor.")
                LabeledContent("Alvo \(item.intensityScale.label)") {
                    CommitTextField("Alvo de intensidade", value: item.intensityTarget, placeholder: "—") { store.changeTarget($0, item: item) }
                        .frame(width: 80)
                }
                Button("Usar descanso padrão em todas as séries") { store.resetRestOverrides(of: item) }
                    .font(.caption)
            }
            Section("Notas neste treino") {
                CommitNotes(value: item.notes) { value in store.updateItem(item) { item.notes = value } }
            }
            Section("Séries") {
                ForEach(SetKind.allCases.filter { kind in item.sets.contains { $0.kind == kind } }) { kind in
                    HStack {
                        SetGlyph(kind: kind)
                        Text(kind.label)
                        Spacer()
                        Text("\(item.sets.filter { $0.kind == kind }.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Duplicar exercício", action: duplicate)
                Button("Remover do treino", role: .destructive, action: remove)
            }
        }.formStyle(.grouped).id(item.id)
    }
}

struct ExerciseInspector: View {
    let exercise: Exercise
    let workouts: [WorkoutTemplate]
    let store: WorkoutStore
    let edit: () -> Void
    let openWorkout: (WorkoutTemplate) -> Void
    let delete: () -> Void
    var body: some View {
        Form {
            Section {
                Text(exercise.name).font(.title3.weight(.semibold))
                Text(exercise.kind.label).foregroundStyle(.secondary)
                Button("Editar exercício…", action: edit)
            }
            Section("Biblioteca") {
                detail("Principal", exercise.primaryMuscle)
                detail("Secundários", exercise.secondaryMuscles)
                detail("Equipamento", exercise.equipment)
                detail("Padrão", exercise.movementPattern)
            }
            Section("Notas pessoais") {
                CommitNotes(value: exercise.notes) { value in
                    store.updateExercise(exercise, name: exercise.name, primaryMuscle: exercise.primaryMuscle,
                        secondaryMuscles: exercise.secondaryMuscles, equipment: exercise.equipment,
                        movementPattern: exercise.movementPattern, kind: exercise.kind, notes: value)
                }
            }
            let usedIn = workouts.filter { $0.items.contains { $0.exercise?.id == exercise.id } }
            if !usedIn.isEmpty {
                Section("Treinos com este exercício") {
                    ForEach(usedIn) { workout in Button(workout.name) { openWorkout(workout) } }
                }
            }
            Section {
                Button(exercise.isArchived ? "Restaurar exercício" : "Arquivar exercício") {
                    store.setArchived(exercise, !exercise.isArchived)
                }
                Button("Apagar exercício…", role: .destructive, action: delete)
            }
        }.formStyle(.grouped).id(exercise.id)
    }
    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "—" : value)
    }
}
