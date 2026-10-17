import SwiftUI

struct NameEditorSheet: View {
    let title: String
    let label: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, label: String = "Nome", name: String = "", save: @escaping (String) -> Void) {
        self.title = title; self.label = label; self.save = save; _name = State(initialValue: name)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            Form { TextField(label, text: $name).focused($focused).onSubmit(submit) }
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar", action: submit).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(WorkoutRules.trimmed(name).isEmpty)
            }.padding(16)
        }
        .frame(width: 420, height: 210)
        .onAppear { focused = true }
    }
    private func submit() {
        guard !WorkoutRules.trimmed(name).isEmpty else { return }
        save(name); dismiss()
    }
}

struct ExerciseEditorSheet: View {
    let exercise: Exercise?
    let store: WorkoutStore
    let onSave: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var primary: String
    @State private var secondary: String
    @State private var equipment: String
    @State private var movement: String
    @State private var kind: ExerciseKind
    @State private var notes: String
    @FocusState private var nameFocused: Bool

    init(exercise: Exercise?, store: WorkoutStore, onSave: @escaping (Exercise) -> Void) {
        self.exercise = exercise; self.store = store; self.onSave = onSave
        _name = State(initialValue: exercise?.name ?? "")
        _primary = State(initialValue: exercise?.primaryMuscle ?? "")
        _secondary = State(initialValue: exercise?.secondaryMuscles ?? "")
        _equipment = State(initialValue: exercise?.equipment ?? "")
        _movement = State(initialValue: exercise?.movementPattern ?? "")
        _kind = State(initialValue: exercise?.kind ?? .compound)
        _notes = State(initialValue: exercise?.notes ?? "")
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(exercise == nil ? "Novo exercício" : "Editar exercício")
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            Form {
                Section("Exercício") {
                    TextField("Nome", text: $name).focused($nameFocused)
                    TextField("Músculo principal", text: $primary)
                    TextField("Músculos secundários", text: $secondary)
                    TextField("Equipamento", text: $equipment)
                    TextField("Padrão de movimento", text: $movement)
                    Picker("Tipo", selection: $kind) {
                        ForEach(ExerciseKind.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Notas pessoais") { TextEditor(text: $notes).frame(height: 70) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Text("Somente o nome é obrigatório.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar", action: submit).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(WorkoutRules.trimmed(name).isEmpty)
            }.padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear { nameFocused = true }
    }
    private func submit() {
        guard !WorkoutRules.trimmed(name).isEmpty else { return }
        if let exercise {
            guard store.updateExercise(exercise, name: name, primaryMuscle: primary,
                secondaryMuscles: secondary, equipment: equipment, movementPattern: movement,
                kind: kind, notes: notes) else { return }
            onSave(exercise)
        } else if let created = store.createExercise(name: name, primaryMuscle: primary,
            secondaryMuscles: secondary, equipment: equipment, movementPattern: movement,
            kind: kind, notes: notes) {
            onSave(created)
        } else { return }
        dismiss()
    }
}
