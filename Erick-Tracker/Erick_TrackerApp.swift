import SwiftData
import SwiftUI

@main
struct Erick_TrackerApp: App {
    @State private var app = AppController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isRestoring {
                    ProgressView("Abrindo seus dados…").frame(minWidth: 1024, minHeight: 700)
                } else if let container = app.persistence.container, let store = app.persistence.store {
                    ContentView(store: store, account: app).modelContainer(container).id(ObjectIdentifier(container))
                } else {
                    ContentUnavailableView {
                        Label("Não foi possível abrir seus dados", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Os dados existentes foram preservados. \(app.persistence.startupError ?? "Tente abrir novamente.")")
                            .textSelection(.enabled)
                    } actions: {
                        Button("Tentar novamente") { app.persistence.open() }.buttonStyle(.borderedProminent)
                    }.frame(minWidth: 1024, minHeight: 700)
                }
            }
            .onOpenURL { url in Task { await app.handle(url) } }
            .onChange(of: scenePhase) { _, phase in app.setActive(phase == .active) }
            .environment(\.locale, WorkoutRules.locale)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands { TrackerCommands() }

        Settings {
            SettingsView(app: app).modelContainer(app.persistence.container ?? (try! PersistenceController.makeContainer(inMemory: true)))
        }
    }
}
