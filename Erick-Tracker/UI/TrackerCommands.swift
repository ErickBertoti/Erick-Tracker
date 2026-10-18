import SwiftUI

struct WorkspaceCommandActions {
    var primaryTitle: String
    var primary: () -> Void
    var newWorkout: () -> Void
    var newProgram: () -> Void
    var search: () -> Void
    var toggleInspector: (() -> Void)?
    var duplicate: (() -> Void)?
    var delete: (() -> Void)?
    var addExercise: (() -> Void)?
    var addSet: (() -> Void)?
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var navigate: (WorkspaceDestination) -> Void
}

private struct WorkspaceCommandsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}
extension FocusedValues {
    var trackerCommands: WorkspaceCommandActions? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
}

struct TrackerCommands: Commands {
    @FocusedValue(\.trackerCommands) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(actions?.primaryTitle ?? "Novo treino") { actions?.primary() }
                .keyboardShortcut("n").disabled(actions == nil)
            Button("Novo treino…") { actions?.newWorkout() }
                .keyboardShortcut("n", modifiers: [.command, .option]).disabled(actions == nil)
            Button("Novo programa…") { actions?.newProgram() }.disabled(actions == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicar") { actions?.duplicate?() }.keyboardShortcut("d")
                .disabled(actions?.duplicate == nil)
            Button("Apagar…") { actions?.delete?() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.delete == nil)
            Button("Buscar") { actions?.search() }.keyboardShortcut("f").disabled(actions == nil)
        }
        CommandMenu("Treino") {
            Button("Adicionar exercício…") { actions?.addExercise?() }.disabled(actions?.addExercise == nil)
            Button("Adicionar série") { actions?.addSet?() }.keyboardShortcut(.return, modifiers: .command)
                .disabled(actions?.addSet == nil)
            Divider()
            Button("Mover exercício para cima") { actions?.moveUp?() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(actions?.moveUp == nil)
            Button("Mover exercício para baixo") { actions?.moveDown?() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(actions?.moveDown == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Mostrar inspetor") { actions?.toggleInspector?() }
                .keyboardShortcut("i", modifiers: [.command, .option]).disabled(actions?.toggleInspector == nil)
            Divider()
            Button("Início") { actions?.navigate(.home) }.keyboardShortcut("1").disabled(actions == nil)
            Button("Treinos") { actions?.navigate(.workouts) }.keyboardShortcut("2").disabled(actions == nil)
            Button("Exercícios") { actions?.navigate(.exercises) }.keyboardShortcut("3").disabled(actions == nil)
            Button("Progresso") { actions?.navigate(.progress) }.keyboardShortcut("4").disabled(actions == nil)
            Button("Histórico") { actions?.navigate(.history) }.keyboardShortcut("5").disabled(actions == nil)
        }
    }
}
