import ActivityKit
import SwiftUI
import WidgetKit

@main struct TrackerLiveActivityBundle: WidgetBundle {
    var body: some Widget { WorkoutLiveActivity() }
}
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(context.attributes.workoutName, systemImage: "figure.strengthtraining.traditional").font(.headline).lineLimit(1)
                    Spacer()
                    ActivityTimer(state: context.state, stale: context.isStale)
                }
                Text(context.state.exercise).font(.subheadline).lineLimit(1)
                ProgressView(value: Double(context.state.completedSets), total: Double(max(1, context.state.totalSets))).tint(.teal)
                Text("\(context.state.completedSets) de \(context.state.totalSets) séries realizadas")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().activityBackgroundTint(.black.opacity(0.12))
                .widgetURL(URL(string: "ericktracker://session/\(context.attributes.sessionID.uuidString)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Erick Tracker", systemImage: "figure.strengthtraining.traditional").font(.caption).foregroundStyle(.teal)
                }
                DynamicIslandExpandedRegion(.trailing) { ActivityTimer(state: context.state, stale: context.isStale) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(context.state.exercise).font(.headline).lineLimit(1)
                        HStack {
                            Text(context.attributes.workoutName).lineLimit(1)
                            Spacer()
                            Text("\(context.state.completedSets)/\(context.state.totalSets) séries")
                        }.font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: Double(context.state.completedSets), total: Double(max(1, context.state.totalSets))).tint(.teal)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.teal)
            } compactTrailing: {
                ActivityTimer(state: context.state, stale: context.isStale).font(.caption).frame(maxWidth: 64)
            } minimal: {
                if context.state.restEndsAt != nil { Image(systemName: "timer").foregroundStyle(.teal) }
                else { Image(systemName: "figure.strengthtraining.traditional").foregroundStyle(.teal) }
            }
            .widgetURL(URL(string: "ericktracker://session/\(context.attributes.sessionID.uuidString)"))
            .keylineTint(.teal)
        }
    }
}
private struct ActivityTimer: View {
    let state: WorkoutActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        if state.paused { Label("Pausa", systemImage: "pause.fill").font(.caption) }
        else if stale && state.restEndsAt != nil { Text("Pronto").font(.caption).foregroundStyle(.teal) }
        else if let start = state.restStartedAt, let end = state.restEndsAt, end > start {
            Text(timerInterval: start...end, countsDown: true, showsHours: false)
                .monospacedDigit().contentTransition(.numericText()).accessibilityLabel("Descanso restante")
        } else { Text("\(state.completedSets)/\(state.totalSets)").monospacedDigit().accessibilityLabel("Séries realizadas") }
    }
}

#Preview("Descanso", as: .content, using: WorkoutActivityAttributes(sessionID: UUID(), workoutName: "Treino A", startedAt: .now)) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState(exercise: "Supino inclinado", completedSets: 2, totalSets: 12, paused: false,
        restStartedAt: .now, restEndsAt: .now.addingTimeInterval(120))
}
