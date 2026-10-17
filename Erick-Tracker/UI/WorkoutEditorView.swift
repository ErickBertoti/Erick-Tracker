import SwiftUI

struct WorkoutEditorView: View {
    let workout: WorkoutTemplate
    let store: WorkoutStore
    @Bindable var navigation: WorkspaceState
    let addExercise: () -> Void

    var body: some View {
        Group {
            if workout.items.isEmpty {
                EmptyWorkspace(title: "Este treino ainda não tem exercícios", icon: "list.bullet.rectangle",
                    message: "Adicione exercícios da biblioteca e configure suas séries na ordem em que deseja executá-las.",
                    actionTitle: "Adicionar exercício", action: addExercise)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("\(WorkoutRules.count(workout.items.count, singular: "exercício", plural: "exercícios")) · \(WorkoutRules.count(workout.totalSetCount, singular: "série", plural: "séries")) · ≈ \(workout.estimatedMinutes) min")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if workout.isArchived { Label("Arquivado", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(workout.orderedItems) { item in
                            ExerciseBlockView(item: item, store: store, navigation: navigation)
                        }
                        Button(action: addExercise) { Label("Adicionar exercício", systemImage: "plus") }
                            .buttonStyle(.bordered).padding(.top, 4)
                        HStack(spacing: 12) {
                            ForEach(SetKind.allCases) { kind in
                                HStack(spacing: 4) { SetGlyph(kind: kind); Text(kind.label) }
                            }
                        }.font(.caption2).foregroundStyle(.secondary).padding(.vertical, 8)
                    }.padding(20)
                }
            }
        }.id(workout.id)
    }
}

private struct ExerciseBlockView: View {
    let item: WorkoutItem
    let store: WorkoutStore
    @Bindable var navigation: WorkspaceState
    @State private var isDropTarget = false
    @State private var blockHeight: CGFloat = 0
    private var selected: Bool { navigation.selectedItemID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    .draggable(item.id.uuidString).help("Arraste para reordenar")
                Text("\(item.position + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.exercise?.name ?? "Exercício indisponível").font(.headline)
                    Text([item.exercise?.primaryMuscle ?? "", item.exercise?.equipment ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Adicionar série") { navigation.selectedItemID = item.id; store.addSet(to: item) }
                    Button("Duplicar exercício") { navigation.selectedItemID = store.duplicateItem(item)?.id }
                    Button("Mover para cima") { store.moveItem(item, by: -1) }.disabled(item.position == 0)
                    Button("Mover para baixo") { store.moveItem(item, by: 1) }.disabled(item.position == (item.workout?.items.count ?? 1) - 1)
                    Divider()
                    Button("Remover do treino", role: .destructive) { remove() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("Ações do exercício")
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
            .contentShape(Rectangle())
            .onTapGesture { navigation.selectedItemID = item.id; navigation.inspectorVisible = true }
            Divider()
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        header("Tipo", width: 134)
                        header("#", width: 22)
                        header("Reps", width: 68)
                        header("Carga (kg)", width: 78)
                        header(item.intensityScale.label, width: 42)
                        header("Descanso", width: 64)
                        header("Notas", width: 110)
                        Color.clear.frame(width: 42, height: 1)
                    }
                    ForEach(item.orderedSets) { set in
                        SetEditorRow(set: set, item: item, store: store)
                    }
                }.padding(12)
            }
            .simultaneousGesture(TapGesture().onEnded { navigation.selectedItemID = item.id })
            HStack {
                Button { navigation.selectedItemID = item.id; store.addSet(to: item) } label: {
                    Label("Adicionar série", systemImage: "plus")
                }.buttonStyle(.borderless)
                Spacer()
                Text("Descanso padrão \(WorkoutRules.restText(item.restSeconds))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 12).padding(.bottom, 12)
            if !item.notes.isEmpty {
                Text(item.notes).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            isDropTarget ? Color.accentColor : selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
            lineWidth: isDropTarget ? 2 : 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { blockHeight = $0 }
        .dropDestination(for: String.self) { values, location in
            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
            if location.y > blockHeight / 2 { return store.moveItem(id: id, after: item) }
            return store.moveItem(id: id, before: item)
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button("Duplicar exercício") { navigation.selectedItemID = store.duplicateItem(item)?.id }
            Button("Mover para cima") { store.moveItem(item, by: -1) }.disabled(item.position == 0)
            Button("Mover para baixo") { store.moveItem(item, by: 1) }.disabled(item.position == (item.workout?.items.count ?? 1) - 1)
            Divider()
            Button("Remover do treino", role: .destructive, action: remove)
        }
    }
    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
    }
    private func remove() {
        if navigation.selectedItemID == item.id { navigation.selectedItemID = nil }
        store.removeItem(item)
    }
}

private struct SetEditorRow: View {
    let set: SetTemplate
    let item: WorkoutItem
    let store: WorkoutStore
    var body: some View {
        GridRow {
            HStack(spacing: 5) {
                SetGlyph(kind: set.kind)
                Picker("Tipo de série", selection: Binding(get: { set.kind }, set: { value in store.updateSet(set) { set.kind = value } })) {
                    ForEach(SetKind.allCases) { kind in Text(kind.label).tag(kind) }
                }
                .labelsHidden().accessibilityLabel("Tipo de série")
            }.frame(width: 134)
            Text(item.number(for: set).map(String.init) ?? "·")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 22)
            CommitTextField("Repetições", value: set.reps, placeholder: "6–8") {
                value in store.updateSet(set) { set.reps = value }; return true
            }.frame(width: 68)
            CommitTextField("Carga em kg", value: set.load, placeholder: "—") {
                value in store.updateSet(set) { set.load = value }; return true
            }.frame(width: 78)
            CommitTextField(item.intensityScale.label, value: set.intensity, placeholder: "—") {
                store.changeIntensity($0, set: set)
            }.frame(width: 42)
            CommitTextField("Descanso da série", value: set.restSecondsOverride.map(WorkoutRules.restText) ?? "",
                            placeholder: WorkoutRules.restText(item.restSeconds)) { store.changeRest($0, set: set) }
                .frame(width: 64).help("Deixe vazio para usar o descanso padrão do exercício")
            CommitTextField("Nota da série", value: set.notes, placeholder: "Adicionar nota") {
                value in store.updateSet(set) { set.notes = value }; return true
            }.frame(width: 110)
            HStack(spacing: 7) {
                Button { store.duplicateSet(set) } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicar série").accessibilityLabel("Duplicar série")
                Button { store.removeSet(set) } label: { Image(systemName: "minus.circle") }
                    .help("Remover série").accessibilityLabel("Remover série")
            }.buttonStyle(.borderless).foregroundStyle(.secondary).frame(width: 42)
        }
        .padding(.vertical, 2)
        .background(set.kind == .topSet ? Color.accentColor.opacity(0.045) : .clear)
    }
}

struct AddExercisePopover: View {
    let exercises: [Exercise]
    let add: (Exercise) -> Void
    let newExercise: () -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool
    private var visible: [Exercise] {
        exercises.filter { !$0.isArchived && WorkoutRules.matches(query,
            in: [$0.name, $0.primaryMuscle, $0.equipment]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("Adicionar exercício").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            TextField("Buscar exercícios", text: $query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).padding(.horizontal, 12).padding(.bottom, 10)
                .onSubmit(addSelection)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(exercises.contains { !$0.isArchived } ? "Nenhum resultado" : "Sua biblioteca está vazia", systemImage: "magnifyingglass")
                } description: {
                    Text("Cadastre um exercício para adicioná-lo ao treino.")
                } actions: {
                    Button("Cadastrar exercício…", action: newExercise)
                }.frame(height: 220)
            } else {
                List(visible, selection: $selection) { exercise in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercise.name).fontWeight(.medium)
                        Text([exercise.primaryMuscle, exercise.equipment].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(exercise.id)
                        .onTapGesture(count: 2) { add(exercise) }
                }.frame(height: 260)
            }
            Divider()
            HStack {
                Button("Novo…", action: newExercise)
                Spacer()
                Button("Adicionar", action: addSelection).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(visible.isEmpty)
            }.padding(12)
        }
        .frame(width: 360)
        .onAppear { searchFocused = true; selection = visible.first?.id }
        .onChange(of: query) { _, _ in selection = visible.first?.id }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
    }
    private func addSelection() {
        if let exercise = visible.first(where: { $0.id == selection }) ?? visible.first { add(exercise) }
    }
    private func moveSelection(_ offset: Int) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selection } ?? 0
        selection = visible[max(0, min(visible.count - 1, index + offset))].id
    }
}
