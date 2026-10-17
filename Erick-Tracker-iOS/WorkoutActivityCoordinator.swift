import ActivityKit
import Observation
import SwiftUI
import UserNotifications

@MainActor @Observable final class WorkoutActivityCoordinator {
    var notificationStatus = ""
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var notificationDate: Date?
    @ObservationIgnored private var notificationSession: UUID?
    @ObservationIgnored private var generation = UUID()
    func refresh(app: AppController) {
        updateTask?.cancel()
        let generation = UUID(); self.generation = generation
        updateTask = Task { [weak self, weak app] in
            guard let self, let app else { return }
            guard let session = app.sessions?.activeSession else { await self.endAll(); return }
            await self.scheduleNotification(session)
            guard self.generation == generation, !Task.isCancelled,
                  app.sessions?.activeSession?.id == session.id else {
                // A notification add may finish after logout. Reconcile with the
                // current account instead of leaving a stale reminder behind.
                if app.sessions?.activeSession == nil {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["tracker.rest"])
                }
                return
            }
            let existing = Activity<WorkoutActivityAttributes>.activities
            for activity in existing where activity.attributes.sessionID != session.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            guard self.generation == generation, !Task.isCancelled,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let content = ActivityContent(state: self.state(session), staleDate: session.restEndsAt)
            if let activity = existing.first(where: { $0.attributes.sessionID == session.id }) {
                await activity.update(content)
                self.observe(activity, app: app)
            } else if !session.activityDismissed && app.sceneActive {
                do {
                    let attrs = WorkoutActivityAttributes(sessionID: session.id, workoutName: session.name, startedAt: session.startedAt)
                    let activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
                    self.observe(activity, app: app)
                } catch {
                    self.notificationStatus = "A atividade ao vivo não pôde iniciar. Seu treino continua salvo no app."
                }
            }
        }
    }
    private func state(_ session: WorkoutSession) -> WorkoutActivityAttributes.ContentState {
        let e = session.orderedExercises.first { $0.id == session.currentExerciseID }
            ?? session.orderedExercises.first { $0.sets.contains { $0.status == .pending } }
            ?? session.orderedExercises.last
        return .init(exercise: e?.name ?? session.name, completedSets: session.completedSetCount,
                     totalSets: session.totalSetCount, paused: session.status == .paused,
                     restStartedAt: session.restStartedAt, restEndsAt: session.restEndsAt)
    }
    private func observe(_ activity: Activity<WorkoutActivityAttributes>, app: AppController) {
        observation?.cancel()
        observation = Task { [weak app] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .dismissed, let session = app?.sessions?.activeSession,
                   session.id == activity.attributes.sessionID {
                    session.activityDismissed = true
                    try? app?.persistence.store?.context.save()
                }
            }
        }
    }
    func endAll() async {
        generation = UUID(); updateTask?.cancel()
        observation?.cancel(); notificationDate = nil; notificationSession = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["tracker.rest"])
        for activity in Activity<WorkoutActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    func setNotifications(_ enabled: Bool, app: AppController) async {
        UserDefaults.standard.set(enabled, forKey: "restNotifications")
        if enabled {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationStatus = allowed ? "Avisos de descanso ativados." : "Avisos desativados no sistema. Você pode permitir em Ajustes do iPhone."
            } catch { notificationStatus = error.localizedDescription }
        } else { notificationStatus = "Avisos de descanso desativados." }
        notificationDate = nil; refresh(app: app)
    }
    private func scheduleNotification(_ session: WorkoutSession) async {
        let center = UNUserNotificationCenter.current()
        guard UserDefaults.standard.bool(forKey: "restNotifications"), session.status == .inProgress,
              let end = session.restEndsAt, end.timeIntervalSinceNow > 0 else {
            center.removePendingNotificationRequests(withIdentifiers: ["tracker.rest"])
            notificationDate = nil; notificationSession = nil; return
        }
        guard notificationDate != end || notificationSession != session.id else { return }
        let settings = await center.notificationSettings()
        guard !Task.isCancelled,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Descanso concluído"; content.body = "Seu próximo exercício está pronto no Erick Tracker."
        content.sound = .default; content.userInfo = ["sessionID": session.id.uuidString]
        let request = UNNotificationRequest(identifier: "tracker.rest", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false))
        do { try await center.add(request); notificationDate = end; notificationSession = session.id }
        catch { notificationStatus = "O aviso não pôde ser agendado: \(error.localizedDescription)" }
    }
}
