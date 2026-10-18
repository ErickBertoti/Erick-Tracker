import Charts
import SwiftData
import SwiftUI

enum ProgressSection: String, CaseIterable, Identifiable {
    case overview = "Visão geral", body = "Corpo", sleep = "Sono"
    var id: String { rawValue }
}
enum ProgressPeriod: String, CaseIterable, Identifiable {
    case week = "7 dias", month = "30 dias", quarter = "90 dias", year = "1 ano", all = "Tudo"
    var id: String { rawValue }
    var days: Int? { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: nil } }
    func start(endingAt date: Date, timezoneID: String, oldest: Date?) -> Date {
        let c = ProgressRules.calendar(timezoneID)
        guard let days else { return c.startOfDay(for: oldest ?? date) }
        return c.date(byAdding: .day, value: -(days-1), to: c.startOfDay(for: date)) ?? date
    }
}
private enum ProgressDeletion: Identifiable {
    case body(BodyRecord), sleep(SleepRecord)
    var id: UUID { switch self { case .body(let r): r.id; case .sleep(let r): r.id } }
}

struct ProgressRootView: View {
    @Bindable var store: WorkoutStore
    var newEntryRequest = 0
    var referenceDate: Date = .now
    @Query(sort: \BodyRecord.measuredAt, order: .reverse) private var records: [BodyRecord]
    @Query(sort: \SleepRecord.endedAt, order: .reverse) private var sleeps: [SleepRecord]
    @Query private var profiles: [BodyProfile]
    @Query private var conflicts: [SyncConflict]
    @State private var section: ProgressSection = .overview
    @State private var period: ProgressPeriod = .month
    @State private var route: ProgressEntryRoute?
    @State private var deletion: ProgressDeletion?
    private var zone: String { TimeZone.current.identifier }
    private var start: Date {
        period.start(endingAt: referenceDate, timezoneID: zone,
            oldest: ([records.last?.measuredAt,sleeps.last?.endedAt].compactMap { $0 }).min())
    }
    private var visibleRecords: [BodyRecord] { records.filter { $0.measuredAt >= start && $0.measuredAt <= referenceDate } }
    private var visibleSleeps: [SleepRecord] {
        let first = ProgressRules.day(start, timezoneID: zone), last = ProgressRules.day(referenceDate, timezoneID: zone)
        return sleeps.filter { $0.wakeDate >= first && $0.wakeDate <= last }
    }
    private var weights: [WeightPoint] {
        records.compactMap { r in
            guard let v = r.values.first(where: { $0.kind == .weight }), let n = ProgressRules.decimal(v.value) else { return nil }
            return .init(id: r.id, date: r.measuredAt, value: n)
        }
    }
    private var excludedNights: Set<String> {
        Set(conflicts.filter { $0.reasonRaw == "duplicateNight" }.compactMap {
            guard let d = $0.localPayload, let s = try? SnapshotCodec.decode(SleepSnapshot.self, from: d) else { return nil }
            return s.wakeDate
        })
    }
    private var sleepPoints: [SleepPoint] {
        ProgressStatistics.unambiguousNights(sleeps.map { r in
            .init(id: r.id, wakeDate: r.wakeDate, start: r.startedAt, end: r.endedAt,
                startTimezoneID: r.startTimezoneID, endTimezoneID: r.endTimezoneID, awakenings: r.awakenings)
        }, excluding: excludedNights)
    }
    private var visiblePoints: [SleepPoint] {
        let ids = Set(visibleSleeps.map(\.id)); return sleepPoints.filter { ids.contains($0.id) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(iOS)
                sectionPicker
                #endif
                HStack {
                    Text(section.rawValue).font(.title2.bold())
                    Spacer()
                    Picker("Período", selection: $period) { ForEach(ProgressPeriod.allCases) { Text($0.rawValue).tag($0) } }
                        .fixedSize()
                }
                if section == .overview { overview }
                else if section == .body { bodySection }
                else { sleepSection }
            }
            .padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Progresso")
        .environment(\.locale, ProgressRules.locale)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) { sectionPicker.frame(minWidth: 300) }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Registrar peso…") { route = .body(.weight,nil) }
                    Button("Registrar medidas…") { route = .body(.measurements,nil) }
                    Button("Registrar composição…") { route = .body(.composition,nil) }
                    Button("Registrar sono…") { route = .sleep(nil) }
                    Divider(); Button("Perfil corporal…") { route = .profile }
                } label: { Label("Novo registro", systemImage: "plus") }.help("Novo registro (⌘N)")
            }
        }
        .sheet(item: $route) { ProgressEntrySheet(route: $0, store: store) }
        .onChange(of: newEntryRequest) { _, _ in route = section == .sleep ? .sleep(nil) : .body(.weight,nil) }
        .confirmationDialog("Apagar este registro?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Apagar registro", role: .destructive) {
                if let deletion {
                    switch deletion { case .body(let r): _ = BodyStore(store: store).delete(r); case .sleep(let r): _ = SleepStore(store: store).delete(r) }
                }; deletion = nil
            }
        } message: { Text("A exclusão será sincronizada. Os demais registros serão preservados.") }
    }
    private var sectionPicker: some View {
        Picker("Área de progresso", selection: $section) { ForEach(ProgressSection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
    }
    private var empty: some View {
        ContentUnavailableView {
            Label("Comece seu registro pessoal", systemImage: "chart.xyaxis.line")
        } description: { Text("Registre peso, medidas, composição ou uma noite de sono. As seções aparecem conforme houver dados.") } actions: {
            Button("Registrar peso") { route = .body(.weight,nil) }
            Button("Registrar sono") { route = .sleep(nil) }
        }
    }
    @ViewBuilder private var overview: some View {
        if records.isEmpty && sleeps.isEmpty { empty }
        else {
            if !visibleRecords.isEmpty { bodySummary }
            if !visiblePoints.isEmpty { sleepSummary }
            if visibleRecords.isEmpty && visiblePoints.isEmpty { Text("Não há registros neste período. Escolha outro período ou adicione um registro.").foregroundStyle(.secondary) }
            if !excludedNights.isEmpty { conflictNotice }
        }
    }
    @ViewBuilder private var bodySection: some View {
        if let profile = profiles.first, profile.heightCm != nil || profile.birthDate != nil || !profile.notes.isEmpty {
            GroupBox("Perfil") {
                VStack(alignment: .leading, spacing: 10) {
                    if let h = profile.heightCm { LabeledContent("Altura", value: "\(ProgressRules.formatted(h)) cm") }
                    if let b = profile.birthDate { LabeledContent("Nascimento", value: b) }
                    if !profile.notes.isEmpty { Text(profile.notes).textSelection(.enabled) }
                    Button("Editar perfil") { route = .profile }
                }.padding(8)
            }
        }
        if records.isEmpty { empty }
        else if visibleRecords.isEmpty { Text("Não há medições neste período.").foregroundStyle(.secondary) }
        else {
            if visibleRecords.contains(where: { $0.values.contains { $0.kind == .weight } }) {
                WeightTrendChart(points: weights, start: start, end: referenceDate, timezoneID: zone) { route = .body(.all,$0) }
            }
            bodySummary
            GroupBox("Histórico corporal") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleRecords) { r in
                        DisclosureGroup {
                            ForEach(r.orderedValues) { v in LabeledContent(v.kind?.label ?? v.kindRaw, value: "\(ProgressRules.formatted(v.value)) \(v.unit)") }
                            if !r.methodNotes.isEmpty { Text(r.methodNotes).foregroundStyle(.secondary) }
                            if !r.notes.isEmpty { Text(r.notes).textSelection(.enabled) }
                            recordActions(edit: { route = .body(.all,r.id) }, delete: { deletion = .body(r) })
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ProgressRules.timestamp(r.measuredAt, timezoneID: r.timezoneID)).font(.headline)
                                Text(r.orderedValues.map { "\($0.kind?.label ?? $0.kindRaw): \(ProgressRules.formatted($0.value)) \($0.unit)" }.joined(separator: " · ")).font(.caption)
                                if let method = r.method { Text(method.label).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Divider()
                    }
                }.padding(8)
            }
        }
    }
    private var bodySummary: some View {
        GroupBox("Corpo") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(MetricKind.allCases.filter { kind in visibleRecords.contains { $0.values.contains { $0.kind == kind } } }) { kind in
                    MetricSummaryRow(kind: kind, records: visibleRecords)
                }
                if visibleRecords.contains(where: { $0.values.contains { $0.kind == .weight } }) {
                    if let mean = ProgressStatistics.weightMean(weights, endingAt: referenceDate, timezoneID: zone) {
                        LabeledContent("Peso médio em 7 dias", value: "\(mean.formatted(.number.locale(ProgressRules.locale).precision(.fractionLength(0...2)))) kg")
                    } else { Text("A média de peso aparece com 3 registros nos últimos 7 dias.").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(8)
        }
    }
    private var sleepSummary: some View {
        GroupBox("Sono — registro pessoal") {
            VStack(alignment: .leading, spacing: 12) {
                if let last = visiblePoints.last { LabeledContent("Última noite (\(last.wakeDate))", value: ProgressRules.durationLabel(last.duration)) }
                ForEach([7,30], id: \.self) { days in
                    if let mean = ProgressStatistics.sleepMean(sleepPoints, endingOn: ProgressRules.day(referenceDate, timezoneID: zone), days: days) {
                        LabeledContent("Média em \(days) dias", value: ProgressRules.durationLabel(mean))
                    } else { Text("Média de \(days) dias: registre pelo menos \(days == 7 ? 4 : 12) noites nessa janela.").font(.caption).foregroundStyle(.secondary) }
                }
                if let mean = ProgressStatistics.awakeningMean(visiblePoints) {
                    LabeledContent("Despertares médios no período", value: mean.formatted(.number.locale(ProgressRules.locale).precision(.fractionLength(0...2))))
                } else { Text("A média de despertares aparece com 5 noites preenchidas no período.").font(.caption).foregroundStyle(.secondary) }
            }.padding(8)
        }
    }
    private var conflictNotice: some View {
        Label("Há noites com registros simultâneos. Resolva em Conta e sincronização; elas ficam fora das médias.", systemImage: "exclamationmark.bubble")
            .font(.callout).foregroundStyle(.secondary)
    }
    @ViewBuilder private var sleepSection: some View {
        Button("Registrar uma noite de sono") { route = .sleep(nil) }.buttonStyle(.borderedProminent)
        if sleeps.isEmpty { empty }
        else {
            if !excludedNights.isEmpty || visibleSleeps.count != visiblePoints.count { conflictNotice }
            if !visiblePoints.isEmpty {
                sleepSummary
                SleepDurationChart(points: visiblePoints, allPoints: sleepPoints) { route = .sleep($0) }
                SleepScheduleChart(points: visiblePoints)
            }
            if visibleSleeps.isEmpty { Text("Não há noites registradas neste período.").foregroundStyle(.secondary) }
            else {
                GroupBox("Histórico de sono") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleSleeps) { r in
                            DisclosureGroup {
                                Text("Dormiu: \(ProgressRules.timestamp(r.startedAt, timezoneID: r.startTimezoneID))")
                                Text("Acordou: \(ProgressRules.timestamp(r.endedAt, timezoneID: r.endTimezoneID))")
                                Text("\(r.startTimezoneID) → \(r.endTimezoneID)").font(.caption).foregroundStyle(.secondary)
                                if let n = r.awakenings { LabeledContent("Despertares", value: String(n)) }
                                if let q = r.quality { LabeledContent("Qualidade", value: q.label) }
                                if !r.notes.isEmpty { Text(r.notes).textSelection(.enabled) }
                                recordActions(edit: { route = .sleep(r.id) }, delete: { deletion = .sleep(r) })
                            } label: { LabeledContent(r.wakeDate, value: ProgressRules.durationLabel(r.duration)) }
                            Divider()
                        }
                    }.padding(8)
                }
            }
        }
    }
    private func recordActions(edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack {
            Button("Editar…", action: edit)
            Button("Apagar…", role: .destructive, action: delete)
        }.buttonStyle(.borderless).padding(.top,6)
    }
}

private struct MetricSummaryRow: View {
    let kind: MetricKind
    let records: [BodyRecord]
    private var samples: [(record: BodyRecord,value: BodyValue)] {
        records.compactMap { r in r.values.first(where: { $0.kind == kind }).map { (r,$0) } }
    }
    var body: some View {
        if let current = samples.first {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(kind.label, value: "\(ProgressRules.formatted(current.value.value)) \(kind.unit)").font(.headline)
                Text(ProgressRules.timestamp(current.record.measuredAt, timezoneID: current.record.timezoneID)).font(.caption).foregroundStyle(.secondary)
                if kind.isComposition { Text(current.record.method?.label ?? "Não informado").font(.caption).foregroundStyle(.secondary) }
                let comparable = samples.dropFirst().filter { !kind.isComposition || $0.record.method == current.record.method }
                if let previous = comparable.first, let now = ProgressRules.decimal(current.value.value), let before = ProgressRules.decimal(previous.value.value) {
                    let delta = now - before
                    Text("Anterior: \(ProgressRules.formatted(previous.value.value)) \(kind.unit) em \(previous.record.measuredAt.formatted(date: .abbreviated,time: .omitted)) · variação \(delta > 0 ? "+" : "")\(delta.formatted(.number.locale(ProgressRules.locale).precision(.fractionLength(0...6)))) \(kind.unit)")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart(([current] + comparable).reversed(), id: \.record.id) { item in
                        if let n = ProgressRules.decimal(item.value.value) {
                            PointMark(x: .value("Data",item.record.measuredAt),y: .value(kind.label,NSDecimalNumber(decimal:n).doubleValue))
                                .foregroundStyle(.secondary)
                        }
                    }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 35).accessibilityHidden(true)
                }
            }
        }
    }
}
