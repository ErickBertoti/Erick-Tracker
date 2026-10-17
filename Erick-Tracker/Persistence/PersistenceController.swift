import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class PersistenceController {
    var container: ModelContainer?
    var store: WorkoutStore?
    var startupError: String?

    init() { open() }

    func open() {
        do {
            let container = try Self.makeContainer()
            self.container = container
            store = WorkoutStore(context: container.mainContext)
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TrackerSchemaV1.self)
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration("ErickTracker", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("ErickTracker", schema: schema,
                                               isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: TrackerMigrationPlan.self,
                                  configurations: [configuration])
    }
}
