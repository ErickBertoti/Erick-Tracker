import SwiftUI

struct CommitTextField: View {
    let title: String
    let value: String
    var placeholder = ""
    let commit: (String) -> Bool
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(_ title: String, value: String, placeholder: String = "",
         commit: @escaping (String) -> Bool) {
        self.title = title; self.value = value; self.placeholder = placeholder
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .focused($focused)
            .accessibilityLabel(title)
            .onSubmit(save)
            .onChange(of: focused) { _, hasFocus in if !hasFocus { save() } }
            .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
            .onDisappear(perform: save)
            .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
    }

    private func save() {
        guard draft != value else { return }
        if !commit(draft) { draft = value }
    }
}

struct CommitNotes: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(value: String, commit: @escaping (String) -> Void) {
        self.value = value; self.commit = commit; _draft = State(initialValue: value)
    }
    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .frame(minHeight: 72, idealHeight: 90, maxHeight: 130)
            .focused($focused)
            .accessibilityLabel("Notas")
            .onChange(of: focused) { _, focus in if !focus { save() } }
            .onChange(of: value) { _, text in if !focused { draft = text } }
            .onDisappear(perform: save)
            .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
    }
    private func save() { if draft != value { commit(draft) } }
}

struct SetGlyph: View {
    let kind: SetKind
    var body: some View {
        Group {
            switch kind {
            case .warmup:
                Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.3, dash: [2, 2]))
            case .feeder:
                Circle().strokeBorder(.secondary, lineWidth: 1.3)
            case .working:
                Circle().fill(.secondary)
            case .topSet:
                Circle().fill(.tint).padding(2.5).overlay(Circle().strokeBorder(.tint, lineWidth: 1.2))
            case .backOff:
                Circle().strokeBorder(.tint, lineWidth: 1.3)
                    .background(alignment: .bottom) { Rectangle().fill(.tint).frame(height: 6).clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)) }
            case .dropSet:
                RoundedRectangle(cornerRadius: 1).fill(.secondary).padding(1.5).rotationEffect(.degrees(45))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(kind.label)
    }
}

struct EmptyWorkspace: View {
    let title: String
    let icon: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message).frame(maxWidth: 350)
        } actions: {
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SaveStatusView: View {
    @Bindable var store: WorkoutStore
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: store.saveError == nil ? "internaldrive" : "exclamationmark.triangle")
                .foregroundStyle(store.saveError == nil ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.saveError == nil ? "Salvo neste dispositivo" : "Alterações não salvas")
                    .font(.caption)
                if store.saveError != nil {
                    Button("Tentar novamente") { store.save() }.buttonStyle(.borderless).font(.caption)
                } else {
                    Text("Disponível sem conexão").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
