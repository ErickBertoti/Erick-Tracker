import Foundation
import Observation

enum WorkspaceDestination: Hashable {
    case home, workouts, exercises, history, progress, program(UUID)
}

@MainActor @Observable
final class WorkspaceState {
    var destination: WorkspaceDestination = .home
    var selectedWorkoutID: UUID?
    var selectedExerciseID: UUID?
    var selectedItemID: UUID?
    var editingWorkoutID: UUID?
    var inspectorVisible = true
    var search = ""
    var showArchivedWorkouts = false
    var showArchivedExercises = false
    var muscleFilter = ""
    var equipmentFilter = ""
    var kindFilter = ""

    func navigate(to destination: WorkspaceDestination) {
        self.destination = destination
        editingWorkoutID = nil; selectedItemID = nil; search = ""
    }
    func open(_ workout: WorkoutTemplate) {
        destination = workout.program.map { .program($0.id) } ?? .workouts
        editingWorkoutID = workout.id; selectedWorkoutID = workout.id
        selectedItemID = nil; search = ""; inspectorVisible = true
    }
}

enum EditorSheet: Identifiable {
    case program(Program?), exercise(Exercise?), workout(Program?)
    var id: String {
        switch self {
        case .program(let model): "program-\(model?.id.uuidString ?? "new")"
        case .exercise(let model): "exercise-\(model?.id.uuidString ?? "new")"
        case .workout(let program): "workout-\(program?.id.uuidString ?? "new")"
        }
    }
}

enum DeletionRequest: Identifiable {
    case program(Program), exercise(Exercise), workout(WorkoutTemplate)
    var id: UUID {
        switch self {
        case .program(let model): model.id
        case .exercise(let model): model.id
        case .workout(let model): model.id
        }
    }
    var name: String {
        switch self {
        case .program(let model): model.name
        case .exercise(let model): model.name
        case .workout(let model): model.name
        }
    }
    var needsArchive: Bool {
        if case .exercise(let exercise) = self { return !exercise.items.isEmpty }
        return false
    }
    var message: String {
        switch self {
        case .program:
            "Os treinos serão mantidos em Modelos avulsos. Esta ação não pode ser desfeita."
        case .exercise(let exercise) where !exercise.items.isEmpty:
            "Este exercício está em uso em \(Set(exercise.items.compactMap { $0.workout?.id }).count) modelo(s). Arquive-o para manter os treinos existentes."
        case .exercise:
            "O exercício será apagado da biblioteca. Esta ação não pode ser desfeita."
        case .workout:
            "O modelo e suas séries serão apagados. Os exercícios continuarão na biblioteca. Esta ação não pode ser desfeita."
        }
    }
}
