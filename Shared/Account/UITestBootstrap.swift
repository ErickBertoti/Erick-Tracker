#if DEBUG
import Foundation
import SwiftData

@MainActor enum TestRuntime {
    static var isPreviewing: Bool { ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
    static var isUnitTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TRACKER_UNIT_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

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
        if ProcessInfo.processInfo.arguments.contains("-progress-fixture") { addProgressFixtures(store: store) }
        return persistence
    }
    static func addProgressFixtures(store: WorkoutStore) {
        let c = ProgressRules.calendar("America/Sao_Paulo")
        _ = BodyStore(store: store).saveProfile(height: "178", birthDate: nil, notes: "Perfil fictício de teste")
        for i in 0..<14 {
            let date = c.date(byAdding: .day, value: -i, to: .now)!
            _ = BodyStore(store: store).saveRecord(id: UUID(), date: date, timezoneID: "America/Sao_Paulo",
                values: [(.weight, "\(80 + i / 7),\(i % 7)"),(.waist,"90"),(.skeletalMuscleMass,"31,2"),(.leanMass,"56")],
                method: .bioimpedance, methodNotes: "Aparelho fictício", notes: "Somente teste")
            let end = c.date(bySettingHour: 7, minute: 0, second: 0, of: date)!
            _ = SleepStore(store: store).save(id: UUID(), start: end.addingTimeInterval(-Double(7*3600 + i*120)), end: end,
                startTimezoneID: "America/Sao_Paulo", endTimezoneID: "America/Sao_Paulo",
                awakenings: i % 3 == 0 ? "" : String(i % 2), quality: i % 4 == 0 ? nil : .good, notes: "Noite fictícia")
        }
    }
}
#endif
