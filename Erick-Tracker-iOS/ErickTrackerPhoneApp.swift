import SwiftData
import SwiftUI

@main struct ErickTrackerPhoneApp: App {
    @State private var app = AppController()
    @State private var activity = WorkoutActivityCoordinator()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                if app.isRestoring { ProgressView("Abrindo seus dados…") }
                else if let container = app.persistence.container, let store = app.persistence.store,
                        let sessions = app.sessions {
                    PhoneRootView(app: app, store: store, sessions: sessions, activity: activity)
                        .modelContainer(container).id(ObjectIdentifier(container))
                } else {
                    ContentUnavailableView {
                        Label("Não foi possível abrir seus dados", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(app.persistence.startupError ?? "Tente novamente.") }
                    actions: { Button("Tentar novamente") { app.persistence.open() } }
                }
            }
            .environment(\.locale, WorkoutRules.locale)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .tint(.teal)
            .onOpenURL { url in
                if url.host == "session" { app.requestedSessionID = UUID(uuidString: url.lastPathComponent) }
                else { Task { await app.handle(url) } }
            }
            .onChange(of: scenePhase) { _, phase in app.setActive(phase == .active) }
            .task {
                let controller = app
                let coordinator = activity
                controller.onLocalSave = { [weak controller, weak coordinator] in if let controller { coordinator?.refresh(app: controller) } }
                controller.onSignOut = { [weak coordinator] in Task { await coordinator?.endAll() } }
                coordinator.refresh(app: controller)
            }
        }
    }
}
