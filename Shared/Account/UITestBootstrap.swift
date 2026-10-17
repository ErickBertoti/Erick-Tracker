#if DEBUG
import Foundation
import SwiftData

@MainActor enum UITestBootstrap {
    static var storeID: UUID? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-ui-testing"), let index = args.firstIndex(of: "-ui-testing-store"), args.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: args[index + 1])
    }
    static func makePersistence(id: UUID) -> PersistenceController {
        let url = AppController.directory.appending(path: "UITests/\(id.uuidString).store")
        let persistence = PersistenceController(url: url)
        guard let store = persistence.store,
              (try? store.context.fetchCount(FetchDescriptor<WorkoutTemplate>())) == 0 else { return persistence }
        let e = store.createExercise(name: "Supino de teste", primaryMuscle: "Peito")!
        let w = store.createWorkout(name: "Treino de teste")!
        let item = store.addExercise(e, to: w)
        store.updateSet(item.sets[0]) { item.sets[0].kind = .dropSet; item.sets[0].reps = "12 + 10"; item.sets[0].load = "15 → 10" }
        return persistence
    }
}
#endif
