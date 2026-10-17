import SwiftData
import SwiftUI

@main
struct Erick_TrackerApp: App {
    @State private var persistence = PersistenceController()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = persistence.container, let store = persistence.store {
                    ContentView(store: store).modelContainer(container)
                } else {
                    ContentUnavailableView {
                        Label("Não foi possível abrir seus dados", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Os dados existentes foram preservados. \(persistence.startupError ?? "Tente abrir novamente.")")
                            .textSelection(.enabled)
                    } actions: {
                        Button("Tentar novamente") { persistence.open() }.buttonStyle(.borderedProminent)
                    }.frame(minWidth: 1024, minHeight: 700)
                }
            }
            .environment(\.locale, WorkoutRules.locale)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands { TrackerCommands() }

        Settings { SettingsView() }
    }
}
