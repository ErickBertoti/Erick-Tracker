import Foundation
import SwiftData
import Testing
@testable import Erick_Tracker

@Suite("Persistência e regras do planejador", .serialized)
@MainActor
struct WorkoutStoreTests {
    private func makeStore() throws -> (ModelContainer, WorkoutStore) {
        let container = try PersistenceController.makeContainer(inMemory: true)
        return (container, WorkoutStore(context: container.mainContext))
    }

    private func fixture(_ store: WorkoutStore) throws -> (Program, Exercise, WorkoutTemplate, WorkoutItem) {
        let program = try #require(store.createProgram(name: "Programa ABC"))
        let exercise = try #require(store.createExercise(name: "Supino inclinado", primaryMuscle: "Peito", equipment: "Halteres"))
        let workout = try #require(store.createWorkout(name: "Treino A", program: program))
        let item = store.addExercise(exercise, to: workout, defaults: TrainingDefaults())
        return (program, exercise, workout, item)
    }

    @Test("O primeiro banco está completamente vazio")
    func emptyStore() throws {
        let (container, _) = try makeStore()
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Program>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Exercise>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SetTemplate>()) == 0)
    }

    @Test("Nomes são obrigatórios e espaços externos são removidos")
    func requiredNames() throws {
        let (_, store) = try makeStore()
        #expect(store.createProgram(name: " \n ") == nil)
        #expect(store.createExercise(name: " ") == nil)
        #expect(store.createWorkout(name: "") == nil)
        let exercise = try #require(store.createExercise(name: "  Elevação lateral  "))
        #expect(exercise.name == "Elevação lateral")
        #expect(!store.updateExercise(exercise, name: "", primaryMuscle: "", secondaryMuscles: "",
            equipment: "", movementPattern: "", kind: .isolation, notes: ""))
        #expect(exercise.name == "Elevação lateral")
    }

    @Test("Novos blocos têm uma série sem carga ou repetições sugeridas")
    func initialSetAndInheritance() throws {
        let (_, store) = try makeStore()
        let (_, _, _, item) = try fixture(store)
        let set = try #require(item.orderedSets.first)
        #expect(item.sets.count == 1)
        #expect(set.reps.isEmpty && set.load.isEmpty)
        #expect(set.kind == .working)
        #expect(set.restSecondsOverride == nil)
        #expect(set.effectiveRestSeconds == 120)
        #expect(store.changeRest("2:30", item: item))
        #expect(set.effectiveRestSeconds == 150)
        #expect(store.changeRest("0", set: set))
        #expect(set.effectiveRestSeconds == 0)
        #expect(store.changeRest("", set: set))
        #expect(set.effectiveRestSeconds == 150)
    }

    @Test("Aquecimento e feeder não são numerados nem contam volume")
    func setKindsAndNumbering() throws {
        let (_, store) = try makeStore()
        let (_, _, workout, item) = try fixture(store)
        for _ in 1..<SetKind.allCases.count { store.addSet(to: item) }
        for (set, kind) in zip(item.orderedSets, SetKind.allCases) { store.updateSet(set) { set.kind = kind } }
        let sets = item.orderedSets
        #expect(sets.map { item.number(for: $0) } == [nil, nil, 1, 2, 3, 4])
        #expect(workout.workingSetCount == 4)
        #expect(workout.totalSetCount == 6)
    }

    @Test("Duplicar treino copia todos os filhos com novos IDs")
    func duplicateWorkout() throws {
        let (_, store) = try makeStore()
        let (program, exercise, original, item) = try fixture(store)
        let set = try #require(item.orderedSets.first)
        store.updateWorkout(original) { original.notes = "Objetivo pessoal" }
        store.updateItem(item) { item.notes = "Banco 4"; item.repRange = "6–8" }
        store.updateSet(set) {
            set.kind = .dropSet; set.reps = "12 + 10"; set.load = "15 → 10"
            set.notes = "Sem intervalo"; set.restSecondsOverride = 0
        }
        store.addSet(to: item)
        let copy = store.duplicateWorkout(original)
        let copyItem = try #require(copy.orderedItems.first)
        #expect(copy.id != original.id)
        #expect(copy.program?.id == program.id)
        #expect(copy.notes == original.notes)
        #expect(copyItem.id != item.id)
        #expect(copyItem.exercise?.id == exercise.id)
        #expect(copyItem.notes == item.notes)
        #expect(copyItem.repRange == "6–8")
        #expect(Set(copyItem.sets.map(\.id)).isDisjoint(with: Set(item.sets.map(\.id))))
        #expect(copyItem.orderedSets.map(\.load) == ["15 → 10", "15 → 10"])
        #expect(copyItem.orderedSets.map(\.reps) == ["12 + 10", "12 + 10"])
        store.updateSet(try #require(copyItem.orderedSets.first)) { copyItem.orderedSets[0].load = "20 → 15" }
        #expect(set.load == "15 → 10")
    }

    @Test("Duplicações de blocos e séries preservam ordem e referências")
    func duplicateChildren() throws {
        let (_, store) = try makeStore()
        let (_, exercise, workout, first) = try fixture(store)
        let second = store.addExercise(exercise, to: workout)
        let copiedItem = try #require(store.duplicateItem(first))
        #expect(workout.orderedItems.map(\.id) == [first.id, copiedItem.id, second.id])
        #expect(workout.orderedItems.map(\.position) == [0, 1, 2])
        #expect(copiedItem.sets[0].id != first.sets[0].id)
        let originalSet = try #require(first.orderedSets.first)
        let copy = try #require(store.duplicateSet(originalSet))
        #expect(copy.id != originalSet.id)
        #expect(first.orderedSets.map(\.id) == [originalSet.id, copy.id])
        #expect(copiedItem.sets.count == 1)
    }

    @Test("Reordenação respeita limites e rejeita IDs de outro treino")
    func reorderItems() throws {
        let (_, store) = try makeStore()
        let (_, exercise, workout, first) = try fixture(store)
        let second = store.addExercise(exercise, to: workout)
        let third = store.addExercise(exercise, to: workout)
        store.moveItem(first, by: -1)
        #expect(workout.orderedItems.map(\.id) == [first.id, second.id, third.id])
        store.moveItem(third, by: -1)
        #expect(workout.orderedItems.map(\.id) == [first.id, third.id, second.id])
        #expect(store.moveItem(id: second.id, before: first))
        #expect(workout.orderedItems.map(\.id) == [second.id, first.id, third.id])
        #expect(workout.orderedItems.map(\.position) == [0, 1, 2])
        let other = try #require(store.createWorkout(name: "Outro treino"))
        let foreignItem = store.addExercise(exercise, to: other)
        #expect(!store.moveItem(id: foreignItem.id, before: first))
        #expect(other.items.count == 1 && workout.items.count == 3)
    }

    @Test("Excluir programa mantém todos os treinos, inclusive arquivados")
    func deleteProgram() throws {
        let (_, store) = try makeStore()
        let (program, _, workout, _) = try fixture(store)
        store.setArchived(workout, true)
        store.deleteProgram(program)
        #expect(try store.context.fetchCount(FetchDescriptor<Program>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 1)
        #expect(workout.program == nil)
        #expect(workout.isArchived)
        store.setArchived(workout, false)
        #expect(!workout.isArchived && workout.items.count == 1)
    }

    @Test("Arrastar permite soltar antes ou depois, inclusive com só dois blocos")
    func dropBeforeAndAfter() throws {
        let (_, store) = try makeStore()
        let (_, exercise, workout, first) = try fixture(store)
        let second = store.addExercise(exercise, to: workout)
        #expect(store.moveItem(id: first.id, after: second))
        #expect(workout.orderedItems.map(\.id) == [second.id, first.id])
        #expect(store.moveItem(id: first.id, before: second))
        #expect(workout.orderedItems.map(\.id) == [first.id, second.id])
        #expect(!store.moveItem(id: first.id, after: first))
        #expect(workout.orderedItems.map(\.position) == [0, 1])
    }

    @Test("Exercício referenciado não pode ser apagado; arquivamento preserva vínculos")
    func exerciseDeletionProtection() throws {
        let (_, store) = try makeStore()
        let (_, exercise, workout, item) = try fixture(store)
        store.setArchived(workout, true)
        #expect(!store.deleteExercise(exercise))
        #expect(store.operationError != nil)
        store.setArchived(exercise, true)
        #expect(item.exercise?.id == exercise.id)
        #expect(exercise.isArchived)
        store.setArchived(exercise, false)
        #expect(!exercise.isArchived)
        store.deleteWorkout(workout)
        #expect(try store.context.fetchCount(FetchDescriptor<WorkoutItem>()) == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<SetTemplate>()) == 0)
        #expect(exercise.items.isEmpty)
        #expect(store.deleteExercise(exercise))
        #expect(try store.context.fetchCount(FetchDescriptor<Exercise>()) == 0)
    }

    @Test("Remover filhos não deixa séries órfãs e normaliza posições")
    func removeChildren() throws {
        let (_, store) = try makeStore()
        let (_, exercise, workout, item) = try fixture(store)
        let first = try #require(item.orderedSets.first)
        let second = store.addSet(to: item)
        store.removeSet(first)
        #expect(item.orderedSets.map(\.id) == [second.id])
        #expect(second.position == 0)
        let survivor = store.addExercise(exercise, to: workout)
        store.removeItem(item)
        #expect(workout.orderedItems.map(\.id) == [survivor.id])
        #expect(survivor.position == 0)
        #expect(try store.context.fetchCount(FetchDescriptor<SetTemplate>()) == 1)
    }

    @Test("Intensidade e descanso inválidos mantêm o valor anterior")
    func validation() throws {
        let (_, store) = try makeStore()
        let (_, _, _, item) = try fixture(store)
        let set = try #require(item.orderedSets.first)
        #expect(!store.changeIntensity("11", set: set))
        #expect(!store.changeTarget("NaN", item: item))
        #expect(set.intensity == "2" && item.intensityTarget == "2")
        #expect(store.changeIntensity("2,5", set: set))
        #expect(set.intensity == "2,5")
        #expect(!store.changeRest("2:99", set: set))
        #expect(set.restSecondsOverride == nil)
        #expect(!store.changeRest("", item: item))
        #expect(item.restSeconds == 120)
        #expect(store.changeIntensity("", set: set))
        #expect(set.intensity.isEmpty)
    }

    @Test("Trocar RIR/RPE converte valores preenchidos e preserva campos opcionais")
    func intensityConversion() throws {
        let (_, store) = try makeStore()
        let (_, _, _, item) = try fixture(store)
        let first = try #require(item.orderedSets.first)
        let second = store.addSet(to: item)
        store.changeIntensity("2,5", set: first)
        store.changeIntensity("", set: second)
        store.changeScale(of: item, to: .rpe)
        #expect(item.intensityTarget == "8")
        #expect(first.intensity == "7,5")
        #expect(second.intensity.isEmpty)
        store.changeScale(of: item, to: .rir)
        #expect(first.intensity == "2,5")
        store.changeRest("0", set: first)
        store.resetRestOverrides(of: item)
        #expect(item.sets.allSatisfy { $0.restSecondsOverride == nil })
    }

    @Test("Busca ignora acentos e combina palavras em campos diferentes")
    func normalizedSearch() {
        #expect(WorkoutRules.matches("ELEVACAO halter", in: ["Elevação lateral", "Halteres"]))
        #expect(WorkoutRules.matches("TRICEPS", in: ["Tríceps francês"]))
        #expect(!WorkoutRules.matches("rosca barra", in: ["Rosca", "Halteres"]))
        #expect(WorkoutRules.matches("   ", in: []))
        #expect(WorkoutRules.parseRest("2:30") == 150)
        #expect(WorkoutRules.parseRest("150") == 150)
        #expect(WorkoutRules.parseRest("-1") == nil)
        #expect(WorkoutRules.parseRest("1:60") == nil)
        #expect(WorkoutRules.parseRest(String(Int.max)) == nil)
    }

    @Test("Falhas de gravação preservam alterações para uma nova tentativa")
    func saveRetry() throws {
        struct DiskFailure: Error { }
        let container = try PersistenceController.makeContainer(inMemory: true)
        var shouldFail = true
        let store = WorkoutStore(context: container.mainContext) { context in
            if shouldFail { throw DiskFailure() }
            try context.save()
        }
        let exercise = try #require(store.createExercise(name: "Puxada frontal"))
        #expect(store.saveError != nil)
        #expect(store.context.hasChanges)
        shouldFail = false
        #expect(store.save())
        #expect(store.saveError == nil)
        #expect(!store.context.hasChanges)
        let secondContext = ModelContext(container)
        #expect(try secondContext.fetch(FetchDescriptor<Exercise>()).first?.id == exercise.id)
    }

    @Test("Reabrir o arquivo preserva IDs, textos compostos, relações e ordem")
    func diskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ErickTrackerTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tracker.store")
        var savedWorkoutID: UUID?
        var savedExerciseID: UUID?
        var savedItemIDs: [UUID] = []
        do {
            let container = try PersistenceController.makeContainer(url: url)
            let store = WorkoutStore(context: container.mainContext)
            let (_, exercise, workout, item) = try fixture(store)
            let set = try #require(item.orderedSets.first)
            store.updateSet(set) { set.kind = .dropSet; set.reps = "12 + 10"; set.load = "15 → 10"; set.notes = "Pausa de 1 s" }
            store.updateItem(item) { item.repRange = "6–8"; item.notes = "Banco 4" }
            let second = store.addExercise(exercise, to: workout)
            store.moveItem(second, by: -1)
            savedWorkoutID = workout.id; savedExerciseID = exercise.id
            savedItemIDs = workout.orderedItems.map(\.id)
            #expect(store.save())
        }
        let reopened = try PersistenceController.makeContainer(url: url)
        let workout = try #require(reopened.mainContext.fetch(FetchDescriptor<WorkoutTemplate>()).first)
        #expect(workout.id == savedWorkoutID)
        #expect(workout.program?.name == "Programa ABC")
        #expect(workout.orderedItems.map(\.id) == savedItemIDs)
        let item = try #require(workout.orderedItems.last)
        #expect(item.exercise?.id == savedExerciseID)
        #expect(item.repRange == "6–8" && item.notes == "Banco 4")
        let set = try #require(item.orderedSets.first)
        #expect(set.kind == .dropSet && set.reps == "12 + 10" && set.load == "15 → 10")
        #expect(set.notes == "Pausa de 1 s" && set.restSecondsOverride == nil)
    }
}
