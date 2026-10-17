import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class WorkoutStore {
    let context: ModelContext
    // A ModelContext does not keep its container alive by itself.
    private let container: ModelContainer
    var saveError: String?
    var operationError: String?
    var lastSavedAt: Date?
    @ObservationIgnored var onSave: (() -> Void)?
    private let saveContext: (ModelContext) throws -> Void

    init(context: ModelContext, saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.container = context.container
        self.saveContext = saveContext
        context.autosaveEnabled = false
    }

    @discardableResult func save() -> Bool {
        do {
            try SyncJournal.capture(in: context)
            try saveContext(context)
            saveError = nil
            lastSavedAt = .now
            onSave?()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func validName(_ name: String) -> String? {
        let trimmed = WorkoutRules.trimmed(name)
        guard !trimmed.isEmpty else {
            operationError = "Preencha um nome para continuar."
            return nil
        }
        return trimmed
    }

    @discardableResult func createProgram(name: String, position: Int = 0) -> Program? {
        guard let name = validName(name) else { return nil }
        let program = Program(name: name, position: position)
        context.insert(program); save()
        return program
    }

    @discardableResult func renameProgram(_ program: Program, name: String) -> Bool {
        guard let name = validName(name) else { return false }
        program.name = name; program.updatedAt = .now; save()
        return true
    }

    func deleteProgram(_ program: Program) {
        for workout in program.workouts {
            workout.program = nil; workout.updatedAt = .now
        }
        context.delete(program); save()
    }

    @discardableResult func createExercise(name: String, primaryMuscle: String = "",
        secondaryMuscles: String = "", equipment: String = "", movementPattern: String = "",
        kind: ExerciseKind = .compound, notes: String = "") -> Exercise? {
        guard let name = validName(name) else { return nil }
        let exercise = Exercise(name: name, primaryMuscle: WorkoutRules.trimmed(primaryMuscle),
            secondaryMuscles: WorkoutRules.trimmed(secondaryMuscles), equipment: WorkoutRules.trimmed(equipment),
            movementPattern: WorkoutRules.trimmed(movementPattern), kind: kind, notes: notes)
        context.insert(exercise); save()
        return exercise
    }

    @discardableResult func updateExercise(_ exercise: Exercise, name: String, primaryMuscle: String,
        secondaryMuscles: String, equipment: String, movementPattern: String,
        kind: ExerciseKind, notes: String) -> Bool {
        guard let name = validName(name) else { return false }
        exercise.name = name; exercise.primaryMuscle = WorkoutRules.trimmed(primaryMuscle)
        exercise.secondaryMuscles = WorkoutRules.trimmed(secondaryMuscles)
        exercise.equipment = WorkoutRules.trimmed(equipment)
        exercise.movementPattern = WorkoutRules.trimmed(movementPattern)
        exercise.kind = kind; exercise.notes = notes; exercise.updatedAt = .now
        save(); return true
    }

    @discardableResult func duplicateExercise(_ exercise: Exercise) -> Exercise? {
        createExercise(name: exercise.name + " (cópia)", primaryMuscle: exercise.primaryMuscle,
            secondaryMuscles: exercise.secondaryMuscles, equipment: exercise.equipment,
            movementPattern: exercise.movementPattern, kind: exercise.kind, notes: exercise.notes)
    }

    func setArchived(_ exercise: Exercise, _ archived: Bool) {
        exercise.isArchived = archived; exercise.updatedAt = .now; save()
    }

    @discardableResult func deleteExercise(_ exercise: Exercise) -> Bool {
        guard exercise.items.isEmpty else {
            operationError = "Este exercício está em uso em um modelo. Arquive-o para manter os treinos existentes."
            return false
        }
        context.delete(exercise); save(); return true
    }

    @discardableResult func createWorkout(name: String, program: Program? = nil) -> WorkoutTemplate? {
        guard let name = validName(name) else { return nil }
        let workout = WorkoutTemplate(name: name, program: program,
            position: nextWorkoutPosition(in: program))
        context.insert(workout); save()
        return workout
    }

    @discardableResult func renameWorkout(_ workout: WorkoutTemplate, name: String) -> Bool {
        guard let name = validName(name) else { return false }
        updateWorkout(workout) { workout.name = name }; return true
    }

    func updateWorkout(_ workout: WorkoutTemplate, _ change: () -> Void) {
        guard workout.modelContext != nil else { return }
        change(); workout.updatedAt = .now; save()
    }

    func assign(_ workout: WorkoutTemplate, to program: Program?) {
        guard workout.program?.id != program?.id else { return }
        updateWorkout(workout) {
            workout.position = nextWorkoutPosition(in: program)
            workout.program = program
        }
    }

    private func nextWorkoutPosition(in program: Program?) -> Int {
        let all = (try? context.fetch(FetchDescriptor<WorkoutTemplate>())) ?? []
        return (all.filter { $0.program?.id == program?.id }.map(\.position).max() ?? -1) + 1
    }

    func setArchived(_ workout: WorkoutTemplate, _ archived: Bool) {
        updateWorkout(workout) { workout.isArchived = archived }
    }

    func deleteWorkout(_ workout: WorkoutTemplate) { context.delete(workout); save() }

    @discardableResult func duplicateWorkout(_ original: WorkoutTemplate) -> WorkoutTemplate {
        let copy = WorkoutTemplate(name: original.name + " (cópia)", program: original.program,
                                   position: nextWorkoutPosition(in: original.program))
        copy.notes = original.notes
        context.insert(copy)
        for item in original.orderedItems {
            if let cloned = cloneItem(item) { cloned.workout = copy }
        }
        save(); return copy
    }

    @discardableResult func addExercise(_ exercise: Exercise, to workout: WorkoutTemplate,
                                        defaults: TrainingDefaults = .read()) -> WorkoutItem {
        let item = WorkoutItem(exercise: exercise, position: workout.items.count,
            restSeconds: defaults.restSeconds, intensityScale: defaults.intensityScale,
            intensityTarget: defaults.intensityTarget)
        context.insert(item); item.workout = workout
        let set = SetTemplate(intensity: defaults.intensityTarget)
        context.insert(set); set.item = item
        touch(item); save(); return item
    }

    func updateItem(_ item: WorkoutItem, _ change: () -> Void) {
        guard item.modelContext != nil else { return }
        change(); touch(item); save()
    }
    func updateSet(_ set: SetTemplate, _ change: () -> Void) {
        guard set.modelContext != nil else { return }
        change(); set.updatedAt = .now
        if let item = set.item { touch(item) }
        save()
    }
    func changeScale(of item: WorkoutItem, to scale: IntensityScale) {
        guard item.intensityScale != scale else { return }
        func converted(_ text: String) -> String {
            guard !text.isEmpty, let number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return text }
            return (10 - number).formatted(.number.locale(WorkoutRules.locale).precision(.fractionLength(0...1)))
        }
        updateItem(item) {
            item.intensityScale = scale; item.intensityTarget = converted(item.intensityTarget)
            for set in item.sets { set.intensity = converted(set.intensity); set.updatedAt = .now }
        }
    }
    func resetRestOverrides(of item: WorkoutItem) {
        updateItem(item) {
            for set in item.sets { set.restSecondsOverride = nil; set.updatedAt = .now }
        }
    }
    private func touch(_ item: WorkoutItem) {
        item.updatedAt = .now; item.workout?.updatedAt = .now
    }

    @discardableResult func changeIntensity(_ text: String, set: SetTemplate) -> Bool {
        guard validateIntensity(text) else { return false }
        updateSet(set) { set.intensity = WorkoutRules.trimmed(text) }; return true
    }
    @discardableResult func changeTarget(_ text: String, item: WorkoutItem) -> Bool {
        guard validateIntensity(text) else { return false }
        updateItem(item) { item.intensityTarget = WorkoutRules.trimmed(text) }; return true
    }
    private func validateIntensity(_ text: String) -> Bool {
        guard WorkoutRules.validIntensity(text) else {
            operationError = "Informe uma intensidade entre 0 e 10, ou deixe o campo vazio."
            return false
        }
        return true
    }

    @discardableResult func changeRest(_ text: String, set: SetTemplate) -> Bool {
        let value = WorkoutRules.trimmed(text)
        if value.isEmpty {
            updateSet(set) { set.restSecondsOverride = nil }; return true
        }
        guard let seconds = WorkoutRules.parseRest(value) else {
            operationError = "Use minutos:segundos (2:30) ou um número de segundos (150)."
            return false
        }
        updateSet(set) { set.restSecondsOverride = seconds }; return true
    }
    @discardableResult func changeRest(_ text: String, item: WorkoutItem) -> Bool {
        guard let seconds = WorkoutRules.parseRest(text) else {
            operationError = "Preencha o descanso como 2:30 ou em segundos."
            return false
        }
        updateItem(item) { item.restSeconds = seconds }; return true
    }

    @discardableResult func addSet(to item: WorkoutItem) -> SetTemplate {
        let last = item.orderedSets.last
        let set = SetTemplate(position: item.sets.count, kind: last?.kind ?? .working,
            reps: last?.reps ?? item.repRange, load: last?.load ?? "",
            intensity: last?.intensity ?? item.intensityTarget,
            restSecondsOverride: last?.restSecondsOverride, notes: last?.notes ?? "")
        context.insert(set); set.item = item; touch(item); save(); return set
    }

    @discardableResult func duplicateSet(_ original: SetTemplate) -> SetTemplate? {
        guard let item = original.item else { return nil }
        let set = cloneSet(original)
        var ordered = item.orderedSets
        let index = ordered.firstIndex { $0.id == original.id } ?? ordered.count - 1
        ordered.insert(set, at: index + 1); set.item = item
        for (position, row) in ordered.enumerated() { row.position = position }
        touch(item); save(); return set
    }
    private func cloneSet(_ original: SetTemplate) -> SetTemplate {
        let copy = SetTemplate(position: original.position, kind: original.kind,
            reps: original.reps, load: original.load, intensity: original.intensity,
            restSecondsOverride: original.restSecondsOverride, notes: original.notes)
        context.insert(copy); return copy
    }
    private func cloneItem(_ original: WorkoutItem) -> WorkoutItem? {
        guard let exercise = original.exercise else { return nil }
        let copy = WorkoutItem(exercise: exercise, position: original.position,
            restSeconds: original.restSeconds, intensityScale: original.intensityScale,
            intensityTarget: original.intensityTarget)
        copy.repRange = original.repRange; copy.notes = original.notes
        context.insert(copy)
        for set in original.orderedSets { cloneSet(set).item = copy }
        return copy
    }

    @discardableResult func duplicateItem(_ original: WorkoutItem) -> WorkoutItem? {
        guard let workout = original.workout, let copy = cloneItem(original) else { return nil }
        var ordered = workout.orderedItems
        let index = ordered.firstIndex { $0.id == original.id } ?? ordered.count - 1
        ordered.insert(copy, at: index + 1); copy.workout = workout
        for (position, item) in ordered.enumerated() { item.position = position; item.updatedAt = .now }
        workout.updatedAt = .now; save(); return copy
    }

    func removeSet(_ set: SetTemplate) {
        let item = set.item
        let remaining = item?.orderedSets.filter { $0.id != set.id } ?? []
        context.delete(set)
        for (position, row) in remaining.enumerated() { row.position = position }
        if let item { touch(item) }; save()
    }
    func removeItem(_ item: WorkoutItem) {
        let workout = item.workout
        let remaining = workout?.orderedItems.filter { $0.id != item.id } ?? []
        context.delete(item)
        for (position, row) in remaining.enumerated() { row.position = position; row.updatedAt = .now }
        workout?.updatedAt = .now; save()
    }

    func moveItem(_ item: WorkoutItem, by offset: Int) {
        guard let workout = item.workout else { return }
        var ordered = workout.orderedItems
        guard let source = ordered.firstIndex(where: { $0.id == item.id }),
              ordered.indices.contains(source + offset) else { return }
        ordered.remove(at: source); ordered.insert(item, at: source + offset)
        applyOrder(ordered, in: workout)
    }
    func moveItem(id: UUID, before target: WorkoutItem) -> Bool {
        moveItem(id: id, relativeTo: target, after: false)
    }
    func moveItem(id: UUID, after target: WorkoutItem) -> Bool {
        moveItem(id: id, relativeTo: target, after: true)
    }
    private func moveItem(id: UUID, relativeTo target: WorkoutItem, after: Bool) -> Bool {
        guard let workout = target.workout, id != target.id else { return false }
        var ordered = workout.orderedItems
        guard let source = ordered.firstIndex(where: { $0.id == id }) else { return false }
        let item = ordered.remove(at: source)
        guard let destination = ordered.firstIndex(where: { $0.id == target.id }) else { return false }
        ordered.insert(item, at: destination + (after ? 1 : 0))
        applyOrder(ordered, in: workout); return true
    }
    private func applyOrder(_ ordered: [WorkoutItem], in workout: WorkoutTemplate) {
        for (position, item) in ordered.enumerated() { item.position = position; item.updatedAt = .now }
        workout.updatedAt = .now; save()
    }
}
