import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "Sistema"; case .light: "Claro"; case .dark: "Escuro" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("defaultRestSeconds") private var restSeconds = 120
    @AppStorage("defaultIntensityScale") private var intensityScale = IntensityScale.rir.rawValue
    @AppStorage("defaultIntensityTarget") private var intensityTarget = 2.0
    var body: some View {
        TabView {
            Form {
                Section("Erick Tracker") {
                    LabeledContent("Armazenamento", value: "Neste Mac")
                    LabeledContent("Unidade de carga", value: "kg")
                    LabeledContent("Idioma", value: "Português (Brasil)")
                }
                Section {
                    Text("Seus exercícios e modelos de treino ficam disponíveis sem conexão.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Geral", systemImage: "gearshape") }

            Form {
                Section {
                    Stepper("Descanso padrão: \(WorkoutRules.restText(restSeconds))", value: $restSeconds, in: 0...900, step: 15)
                    Picker("Escala de intensidade", selection: $intensityScale) {
                        ForEach(IntensityScale.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Stepper("Alvo: \(intensityTarget.formatted(.number.locale(WorkoutRules.locale)))", value: $intensityTarget, in: 0...10, step: 0.5)
                } header: {
                    Text("Novos exercícios no treino")
                } footer: {
                    Text("As preferências são aplicadas ao adicionar um exercício. Cada bloco e série pode ser ajustado no editor.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Treino", systemImage: "figure.strengthtraining.traditional") }

            Form {
                Picker("Aparência", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .tabItem { Label("Aparência", systemImage: "circle.lefthalf.filled") }
        }
        .frame(width: 520, height: 340)
        .environment(\.locale, WorkoutRules.locale)
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }
}
