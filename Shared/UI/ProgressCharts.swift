import Charts
import SwiftUI

nonisolated struct RollingWeightPoint: Identifiable {
    var date: Date; var value: Double; var segment: Int
    var id: Date { date }
}
struct WeightTrendChart: View {
    let points: [WeightPoint]
    let start: Date
    let end: Date
    let timezoneID: String
    let edit: (UUID) -> Void
    @State private var selectedDate: Date?
    private var visible: [WeightPoint] { points.filter { $0.date >= start && $0.date <= end } }
    private var selected: WeightPoint? {
        guard let selectedDate else { return nil }
        return visible.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var averages: [RollingWeightPoint] {
        let c = ProgressRules.calendar(timezoneID)
        var day = c.startOfDay(for: start), result: [RollingWeightPoint] = [], segment = 0
        while day <= end {
            if let value = ProgressStatistics.weightMean(points, endingAt: day, timezoneID: timezoneID) {
                result.append(.init(date: day, value: NSDecimalNumber(decimal: value).doubleValue, segment: segment))
            } else { segment += 1 }
            guard let next = c.date(byAdding: .day, value: 1, to: day) else { break }; day = next
        }
        return result
    }
    var body: some View {
        GroupBox("Peso — registros e média móvel de 7 dias") {
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(visible) { point in
                        PointMark(x: .value("Data", point.date), y: .value("Peso em kg", point.plotValue))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityValue("\(ProgressRules.formatted(NSDecimalNumber(decimal: point.value).stringValue)) kg")
                    }
                    ForEach(averages) { point in
                        LineMark(x: .value("Data", point.date), y: .value("Média de peso em kg", point.value), series: .value("Trecho", point.segment))
                            .foregroundStyle(.teal).interpolationMethod(.linear)
                    }
                    if let selected {
                        RuleMark(x: .value("Registro selecionado", selected.date)).foregroundStyle(.secondary)
                    }
                }
                .chartXScale(domain: start...max(end,start.addingTimeInterval(60)))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXSelection(value: $selectedDate).frame(height: 240)
                .accessibilityLabel("Evolução do peso. Pontos individuais e média móvel, quando há pelo menos três registros em sete dias.")
                if let selected {
                    Button { edit(selected.id) } label: {
                        Text("\(selected.date.formatted(date: .abbreviated, time: .shortened)): \(ProgressRules.formatted(NSDecimalNumber(decimal: selected.value).stringValue)) kg — editar")
                    }.buttonStyle(.plain)
                }
                Text("Pontos: pesagens individuais. Linha teal: média de pelo menos 3 registros na janela de 7 dias. Dias ausentes não viram zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

struct SleepDurationChart: View {
    let points: [SleepPoint]
    let allPoints: [SleepPoint]
    let edit: (UUID) -> Void
    @State private var selectedDate: Date?
    private var selected: SleepPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs((ProgressRules.civilDate($0.wakeDate) ?? .distantPast).timeIntervalSince(selectedDate)) < abs((ProgressRules.civilDate($1.wakeDate) ?? .distantPast).timeIntervalSince(selectedDate)) }
    }
    var body: some View {
        GroupBox("Duração por noite") {
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(points) { point in
                        if let date = ProgressRules.civilDate(point.wakeDate) {
                            BarMark(x: .value("Data de acordar", date, unit: .day), y: .value("Horas", point.duration / 3600))
                                .foregroundStyle(.teal.opacity(0.7))
                                .accessibilityLabel("Noite de \(point.wakeDate)").accessibilityValue(ProgressRules.durationLabel(point.duration))
                            if let mean = ProgressStatistics.sleepMean(allPoints, endingOn: point.wakeDate, days: 7) {
                                PointMark(x: .value("Data de acordar", date), y: .value("Média móvel em horas", mean / 3600))
                                    .foregroundStyle(.primary).symbol(.diamond)
                            }
                        }
                    }
                    if let selected, let date = ProgressRules.civilDate(selected.wakeDate) {
                        RuleMark(x: .value("Noite selecionada", date)).foregroundStyle(.secondary)
                    }
                }
                .chartXSelection(value: $selectedDate).frame(height: 230).environment(\.timeZone, .gmt)
                .chartYAxisLabel("Horas")
                if let selected {
                    Button("\(selected.wakeDate): \(ProgressRules.durationLabel(selected.duration)) — editar") { edit(selected.id) }.buttonStyle(.plain)
                }
                Text("Barras: duração informada. Losangos: média de 7 dias com pelo menos 4 noites. Registro pessoal.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

struct SleepScheduleChart: View {
    let points: [SleepPoint]
    private func start(_ p: SleepPoint) -> Double {
        let minute = ProgressRules.clockMinutes(p.start, timezoneID: p.startTimezoneID)
        return minute >= 720 ? minute - 1440 : minute
    }
    private func end(_ p: SleepPoint) -> Double {
        var minute = ProgressRules.clockMinutes(p.end, timezoneID: p.endTimezoneID)
        while minute <= start(p) { minute += 1440 }; return minute
    }
    var body: some View {
        GroupBox("Horários locais de dormir e acordar") {
            VStack(alignment: .leading, spacing: 12) {
                Chart(points) { point in
                    if let date = ProgressRules.civilDate(point.wakeDate) {
                        BarMark(x: .value("Data de acordar", date, unit: .day), yStart: .value("Dormiu", start(point)), yEnd: .value("Acordou", end(point)))
                            .foregroundStyle(by: .value("Fusos", point.startTimezoneID + " → " + point.endTimezoneID))
                            .accessibilityLabel("Noite de \(point.wakeDate)")
                            .accessibilityValue("Dormiu às \(ProgressRules.clockLabel(start(point))) e acordou às \(ProgressRules.clockLabel(end(point)))")
                    }
                }
                .chartYAxis { AxisMarks { value in
                    AxisGridLine(); AxisValueLabel { if let minute = value.as(Double.self) { Text(ProgressRules.clockLabel(minute)) } }
                } }
                .frame(height: 220).environment(\.timeZone, .gmt)
                let means = ProgressStatistics.clockMeans(points)
                ForEach(means.keys.sorted(), id: \.self) { zone in
                    if let mean = means[zone] {
                        LabeledContent(zone, value: "Dormiu \(ProgressRules.clockLabel(mean.start)) · acordou \(ProgressRules.clockLabel(mean.end))").font(.caption)
                    }
                }
                if means.isEmpty {
                    Text("Horários médios aparecem com pelo menos 7 noites no período e no mesmo grupo de fusos.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }
}
