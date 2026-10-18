import SwiftData
import SwiftUI

enum BodyEntryMode: String, CaseIterable, Identifiable {
    case weight, measurements, composition, all
    var id: String { rawValue }
    var title: String {
        switch self { case .weight: "Registrar peso"; case .measurements: "Registrar medidas"; case .composition: "Registrar composição"; case .all: "Editar medição" }
    }
    var metrics: [MetricKind] {
        MetricKind.allCases.filter { self == .all || (self == .weight && $0 == .weight) || (self == .measurements && $0.isMeasurement) || (self == .composition && $0.isComposition) }
    }
}
enum ProgressEntryRoute: Identifiable {
    case body(BodyEntryMode, UUID?), sleep(UUID?), profile
    var id: String {
        switch self {
        case .body(let mode, let id): "body-\(id?.uuidString ?? mode.rawValue)"
        case .sleep(let id): "sleep-\(id?.uuidString ?? "new")"
        case .profile: "profile"
        }
    }
}
nonisolated struct MetricFieldDraft: Codable, Equatable, Identifiable {
    var kind: MetricKind; var value: String
    var id: MetricKind { kind }
}
nonisolated struct BodyEntryDraft: Codable, Equatable {
    var id = UUID(); var date = Date.now; var timezoneID = TimeZone.current.identifier
    var values: [MetricFieldDraft] = []; var method: CompositionMethod?
    var methodNotes = ""; var notes = ""
}
nonisolated struct SleepEntryDraft: Codable, Equatable {
    var id = UUID(); var start: Date; var end: Date
    var startTimezoneID = TimeZone.current.identifier; var endTimezoneID = TimeZone.current.identifier
    var awakenings = ""; var quality: SleepQuality?; var notes = ""
    init(now: Date = .now) {
        let c = Calendar.current
        end = c.date(bySettingHour: 7, minute: 0, second: 0, of: now) ?? now
        if end > now { end = c.date(byAdding: .day, value: -1, to: end) ?? end }
        start = c.date(byAdding: .hour, value: -8, to: end) ?? end
    }
}
nonisolated struct ProfileEntryDraft: Codable, Equatable {
    var height = ""; var birthDate: String?; var notes = ""
}

struct ProgressEntrySheet: View {
    let route: ProgressEntryRoute
    let store: WorkoutStore
    var body: some View {
        NavigationStack {
            switch route {
            case .body(let mode, let id): BodyEntryView(store: store, mode: mode, recordID: id, key: route.id)
            case .sleep(let id): SleepEntryView(store: store, recordID: id, key: route.id)
            case .profile: ProfileEntryView(store: store, key: route.id)
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 680)
        #endif
        .environment(\.locale, ProgressRules.locale)
    }
}

private struct EntryStatus: View {
    let restored: Bool; let error: String?
    var body: some View {
        Section {
            if restored { Label("Rascunho recuperado neste aparelho", systemImage: "doc.badge.clock") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Salvar confirma o registro. Ao sair sem confirmar, o rascunho fica neste aparelho. Cancelar descarta o rascunho.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TimezoneField: View {
    let title: String
    @Binding var selection: String
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                Text(id.replacingOccurrences(of: "_", with: " ")).tag(id)
            }
        }
    }
}

struct BodyEntryView: View {
    let store: WorkoutStore
    let mode: BodyEntryMode
    let key: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: BodyEntryDraft
    @State private var finished = false
    @State private var error: String?
    @FocusState private var focusedField: String?
    @ScaledMetric(relativeTo: .body) private var valueFieldWidth = 112
    private let restored: Bool
    init(store: WorkoutStore, mode: BodyEntryMode, recordID: UUID?, key: String) {
        self.store = store; self.mode = mode; self.key = key
        var initial = BodyEntryDraft()
        if let record = try? store.context.fetch(FetchDescriptor<BodyRecord>()).first(where: { $0.id == recordID }) {
            initial.id = record.id; initial.date = record.measuredAt; initial.timezoneID = record.timezoneID
            initial.values = record.orderedValues.compactMap { v in v.kind.map { .init(kind: $0, value: ProgressRules.editable(v.value)) } }
            initial.method = record.method; initial.methodNotes = record.methodNotes; initial.notes = record.notes
        } else if let kind = mode.metrics.first { initial.values = [.init(kind: kind, value: "")] }
        let saved = ProgressDraftStore(store: store).load(BodyEntryDraft.self, key: key)
        restored = saved != nil; _draft = State(initialValue: saved ?? initial)
    }
    var body: some View {
        Form {
            Section("Medição") {
                DatePicker("Data e horário", selection: $draft.date)
                    .environment(\.timeZone, TimeZone(identifier: draft.timezoneID) ?? .current)
                DisclosureGroup("Fuso horário") { TimezoneField(title: "Fuso da medição", selection: $draft.timezoneID) }
            }
            Section("Valores") {
                ForEach($draft.values) { $field in
                    HStack {
                        Text(field.kind.label)
                        Spacer(minLength: 12)
                        TextField(field.kind.label, text: $field.value, prompt: Text("Valor"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: field.kind.rawValue)
                            .frame(width: valueFieldWidth)
                            .accessibilityLabel("\(field.kind.label), \(field.kind.unit)")
                            .accessibilityIdentifier("body-value-\(field.kind.rawValue)")
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text(field.kind.unit).foregroundStyle(.secondary)
                        Button { draft.values.removeAll { $0.kind == field.kind } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remover \(field.kind.label)")
                    }
                }
                Menu("Adicionar métrica") {
                    ForEach(mode.metrics.filter { k in !draft.values.contains { $0.kind == k } }) { kind in
                        Button(kind.label) { draft.values.append(.init(kind: kind, value: "")) }
                    }
                }.disabled(draft.values.count == mode.metrics.count)
            }
            if draft.values.contains(where: { $0.kind.isComposition }) {
                Section("Composição corporal") {
                    Picker("Método", selection: $draft.method) {
                        Text("Selecionar método").tag(nil as CompositionMethod?)
                        ForEach(CompositionMethod.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    TextField("Detalhes do método ou aparelho (opcional)", text: $draft.methodNotes, axis: .vertical)
                        .focused($focusedField, equals: "methodNotes")
                    Text("Massas musculares, massa magra e massa de gordura permanecem métricas distintas.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notas") { TextField("Notas opcionais", text: $draft.notes, axis: .vertical).lineLimit(3...6).focused($focusedField, equals: "notes") }
            EntryStatus(restored: restored, error: error)
        }
        .formStyle(.grouped).navigationTitle(mode.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar", role: .cancel) { cancel() } }
            ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.keyboardShortcut(.defaultAction) }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fechar teclado") { focusedField = nil } }
            #endif
        }
        .task(id: draft) { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { preserve() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preserve() } }
        .onDisappear { preserve() }
    }
    private func preserve() { if !finished { _ = ProgressDraftStore(store: store).save(draft, key: key) } }
    private func cancel() {
        if ProgressDraftStore(store: store).remove(key: key) { finished = true; dismiss() }
        else { error = store.saveError }
    }
    private func save() {
        let okay = BodyStore(store: store).saveRecord(id: draft.id, date: draft.date, timezoneID: draft.timezoneID,
            values: draft.values.map { ($0.kind,$0.value) }, method: draft.method, methodNotes: draft.methodNotes, notes: draft.notes, draftKey: key)
        if okay { finished = true; dismiss() }
        else { error = store.operationError ?? store.saveError; store.operationError = nil; preserve() }
    }
}

struct SleepEntryView: View {
    let store: WorkoutStore
    let key: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: SleepEntryDraft
    @State private var finished = false
    @State private var error: String?
    @FocusState private var focusedField: String?
    @Query private var existing: [SleepRecord]
    private let restored: Bool
    init(store: WorkoutStore, recordID: UUID?, key: String) {
        self.store = store; self.key = key
        var initial = SleepEntryDraft()
        if let r = try? store.context.fetch(FetchDescriptor<SleepRecord>()).first(where: { $0.id == recordID }) {
            initial.id = r.id; initial.start = r.startedAt; initial.end = r.endedAt
            initial.startTimezoneID = r.startTimezoneID; initial.endTimezoneID = r.endTimezoneID
            initial.awakenings = r.awakenings.map(String.init) ?? ""; initial.quality = r.quality; initial.notes = r.notes
        }
        let saved = ProgressDraftStore(store: store).load(SleepEntryDraft.self, key: key)
        restored = saved != nil; _draft = State(initialValue: saved ?? initial)
    }
    private var duplicate: SleepRecord? {
        existing.first { $0.id != draft.id && $0.wakeDate == ProgressRules.day(draft.end, timezoneID: draft.endTimezoneID) }
    }
    var body: some View {
        Form {
            Section("Noite principal") {
                DatePicker("Dormiu", selection: $draft.start).environment(\.timeZone, TimeZone(identifier: draft.startTimezoneID) ?? .current)
                DatePicker("Acordou", selection: $draft.end).environment(\.timeZone, TimeZone(identifier: draft.endTimezoneID) ?? .current)
                LabeledContent("Duração", value: draft.end > draft.start ? ProgressRules.durationLabel(draft.end.timeIntervalSince(draft.start)) : "Confira os horários")
                LabeledContent("Data de acordar", value: ProgressRules.day(draft.end, timezoneID: draft.endTimezoneID))
                DisclosureGroup("Fusos horários") {
                    TimezoneField(title: "Ao dormir", selection: $draft.startTimezoneID)
                    TimezoneField(title: "Ao acordar", selection: $draft.endTimezoneID)
                }
                if let duplicate {
                    Text("Esta noite já tem um registro.").foregroundStyle(.secondary)
                    Button("Editar o registro existente") {
                        draft.id = duplicate.id; draft.start = duplicate.startedAt; draft.end = duplicate.endedAt
                        draft.startTimezoneID = duplicate.startTimezoneID; draft.endTimezoneID = duplicate.endTimezoneID
                        draft.awakenings = duplicate.awakenings.map(String.init) ?? ""; draft.quality = duplicate.quality; draft.notes = duplicate.notes
                    }
                }
            }
            Section("Informações opcionais") {
                TextField("Despertares (vazio = não registrado)", text: $draft.awakenings)
                    .focused($focusedField, equals: "awakenings")
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Picker("Qualidade", selection: $draft.quality) {
                    Text("Não registrada").tag(nil as SleepQuality?)
                    ForEach(SleepQuality.allCases) { Text($0.label).tag(Optional($0)) }
                }
                TextField("Notas", text: $draft.notes, axis: .vertical).lineLimit(3...6).focused($focusedField, equals: "notes")
            }
            Section { Text("Registro pessoal. A duração é calculada pelos horários informados, sem diagnóstico.").font(.caption).foregroundStyle(.secondary) }
            EntryStatus(restored: restored, error: error)
        }
        .formStyle(.grouped).navigationTitle("Registrar sono")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar", role: .cancel) { cancel() } }
            ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() }.keyboardShortcut(.defaultAction).disabled(duplicate != nil) }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fechar teclado") { focusedField = nil } }
            #endif
        }
        .task(id: draft) { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { preserve() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preserve() } }
        .onDisappear { preserve() }
    }
    private func preserve() { if !finished { _ = ProgressDraftStore(store: store).save(draft, key: key) } }
    private func cancel() {
        if ProgressDraftStore(store: store).remove(key: key) { finished = true; dismiss() } else { error = store.saveError }
    }
    private func save() {
        let okay = SleepStore(store: store).save(id: draft.id, start: draft.start, end: draft.end,
            startTimezoneID: draft.startTimezoneID, endTimezoneID: draft.endTimezoneID,
            awakenings: draft.awakenings, quality: draft.quality, notes: draft.notes, draftKey: key)
        if okay { finished = true; dismiss() }
        else { error = store.operationError ?? store.saveError; store.operationError = nil; preserve() }
    }
}

struct ProfileEntryView: View {
    let store: WorkoutStore
    let key: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: ProfileEntryDraft
    @State private var finished = false
    @State private var error: String?
    @FocusState private var focusedField: String?
    private let restored: Bool
    init(store: WorkoutStore, key: String) {
        self.store = store; self.key = key
        var initial = ProfileEntryDraft()
        if let p = try? store.context.fetch(FetchDescriptor<BodyProfile>()).first {
            initial.height = ProgressRules.editable(p.heightCm)
            initial.birthDate = p.birthDate; initial.notes = p.notes
        }
        let saved = ProgressDraftStore(store: store).load(ProfileEntryDraft.self, key: key)
        restored = saved != nil; _draft = State(initialValue: saved ?? initial)
    }
    var body: some View {
        Form {
            Section("Perfil opcional") {
                HStack {
                    TextField("Altura", text: $draft.height)
                        .focused($focusedField, equals: "height")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Text("cm").foregroundStyle(.secondary)
                }
                Toggle("Registrar nascimento", isOn: Binding(get: { draft.birthDate != nil }, set: { draft.birthDate = $0 ? ProgressRules.day(.now, timezoneID: "GMT") : nil }))
                if draft.birthDate != nil {
                    DatePicker("Nascimento", selection: Binding(get: { draft.birthDate.flatMap(ProgressRules.civilDate) ?? .now },
                        set: { draft.birthDate = ProgressRules.day($0, timezoneID: "GMT") }), displayedComponents: .date)
                        .environment(\.timeZone, .gmt)
                }
                TextField("Notas", text: $draft.notes, axis: .vertical).lineLimit(3...6).focused($focusedField, equals: "notes")
                Button("Limpar campos do perfil", role: .destructive) { draft = ProfileEntryDraft() }
            }
            EntryStatus(restored: restored, error: error)
        }
        .formStyle(.grouped).navigationTitle("Perfil corporal")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar", role: .cancel) {
                if ProgressDraftStore(store: store).remove(key: key) { finished = true; dismiss() } else { error = store.saveError }
            } }
            ToolbarItem(placement: .confirmationAction) { Button("Salvar") {
                if BodyStore(store: store).saveProfile(height: draft.height, birthDate: draft.birthDate, notes: draft.notes, draftKey: key) {
                    finished = true; dismiss()
                } else { error = store.operationError ?? store.saveError; store.operationError = nil; preserve() }
            }.keyboardShortcut(.defaultAction) }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Fechar teclado") { focusedField = nil } }
            #endif
        }
        .task(id: draft) { try? await Task.sleep(for: .milliseconds(600)); if !Task.isCancelled { preserve() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preserve() } }
        .onDisappear { preserve() }
    }
    private func preserve() { if !finished { _ = ProgressDraftStore(store: store).save(draft, key: key) } }
}
