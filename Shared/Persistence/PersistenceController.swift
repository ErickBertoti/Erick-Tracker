import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class PersistenceController {
    var container: ModelContainer?
    var store: WorkoutStore?
    var startupError: String?

    private let url: URL?
    private let inMemory: Bool

    init(url: URL? = nil, inMemory: Bool = false) { self.url = url; self.inMemory = inMemory; open() }

    func open() {
        do {
            if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            let container = try Self.makeContainer(inMemory: inMemory, url: url)
            self.container = container
            store = WorkoutStore(context: container.mainContext)
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TrackerSchemaV3.self)
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
