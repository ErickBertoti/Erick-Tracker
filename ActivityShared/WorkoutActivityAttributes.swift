import ActivityKit
import Foundation

nonisolated struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exercise: String
        var completedSets: Int
        var totalSets: Int
        var paused: Bool
        var restStartedAt: Date?
        var restEndsAt: Date?
    }
    var sessionID: UUID
    var workoutName: String
    var startedAt: Date
}
