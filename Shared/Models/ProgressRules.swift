import Foundation

nonisolated enum ProgressFailure: LocalizedError {
    case invalidNumber(String), emptyRecord, methodRequired, invalidDate, invalidSleep, duplicateNight, invalidSnapshot, pendingConflict
    var errorDescription: String? {
        switch self {
        case .invalidNumber(let field): "Confira o valor de \(field). Use um número válido e a unidade indicada."
        case .emptyRecord: "Adicione pelo menos uma métrica com valor."
        case .methodRequired: "Selecione o método de composição, inclusive “Não informado” se você não o conhece."
        case .invalidDate: "Confira a data e o fuso horário informados."
        case .invalidSleep: "O horário de acordar precisa ser posterior ao início. Despertares devem ser um inteiro a partir de zero."
        case .duplicateNight: "Já existe um registro para esta noite. Edite o registro existente ou escolha outra data."
        case .invalidSnapshot: "O registro recebido é incompatível. Atualize o app e tente sincronizar novamente."
        case .pendingConflict: "Resolva primeiro o conflito ou o envio pendente do outro registro desta noite."
        }
    }
}

nonisolated enum ProgressRules {
    static let locale = Locale(identifier: "pt_BR")
    static func decimal(_ text: String) -> Decimal? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.range(of: #"^\d{1,12}([.,]\d{1,6})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: s.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }
    static func canonical(_ text: String, kind: MetricKind) throws -> String {
        guard let n = decimal(text), n >= 0, !kind.requiresPositive || n > 0,
              kind.unit != "%" || n <= 100 else { throw ProgressFailure.invalidNumber(kind.label) }
        return NSDecimalNumber(decimal: n).stringValue
    }
    static func height(_ text: String) throws -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let n = decimal(text), n > 0 else { throw ProgressFailure.invalidNumber("altura") }
        return NSDecimalNumber(decimal: n).stringValue
    }
    static func formatted(_ canonical: String?) -> String {
        guard let canonical, let n = decimal(canonical) else { return "—" }
        return n.formatted(.number.locale(locale).precision(.fractionLength(0...6)))
    }
    static func editable(_ canonical: String?) -> String {
        canonical?.replacingOccurrences(of: ".", with: ",") ?? ""
    }
    static func calendar(_ timezoneID: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timezoneID) ?? .gmt
        return c
    }
    static func day(_ date: Date, timezoneID: String) -> String {
        let p = calendar(timezoneID).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
    static func civilDate(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = calendar("GMT").date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              day(d, timezoneID: "GMT") == text else { return nil }
        return d
    }
    static func clockMinutes(_ date: Date, timezoneID: String) -> Double {
        let p = calendar(timezoneID).dateComponents([.hour, .minute], from: date)
        return Double((p.hour ?? 0) * 60 + (p.minute ?? 0))
    }
    static func clockLabel(_ minutes: Double) -> String {
        let m = (Int(minutes.rounded()) % 1440 + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return "\(minutes / 60) h \(minutes % 60) min"
    }
    static func timestamp(_ date: Date, timezoneID: String) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale,
            timeZone: TimeZone(identifier: timezoneID) ?? .gmt))
    }
    static func circularMean(_ minutes: [Double]) -> Double? {
        guard !minutes.isEmpty else { return nil }
        let x = minutes.reduce(0) { $0 + cos($1 * 2 * .pi / 1440) }
        let y = minutes.reduce(0) { $0 + sin($1 * 2 * .pi / 1440) }
        guard hypot(x, y) / Double(minutes.count) > 0.000001 else { return nil }
        let angle = atan2(y, x) * 1440 / (2 * .pi)
        return angle < 0 ? angle + 1440 : angle
    }
}

nonisolated struct WeightPoint: Identifiable {
    let id: UUID; let date: Date; let value: Decimal
    var plotValue: Double { NSDecimalNumber(decimal: value).doubleValue }
}
nonisolated struct SleepPoint: Identifiable {
    let id: UUID; let wakeDate: String; let start: Date; let end: Date
    let startTimezoneID: String; let endTimezoneID: String; let awakenings: Int?
    var duration: TimeInterval { end.timeIntervalSince(start) }
}
nonisolated enum ProgressStatistics {
    static func weightMean(_ points: [WeightPoint], endingAt date: Date, timezoneID: String) -> Decimal? {
        let c = ProgressRules.calendar(timezoneID), end = c.startOfDay(for: date)
        guard let start = c.date(byAdding: .day, value: -6, to: end),
              let limit = c.date(byAdding: .day, value: 1, to: end) else { return nil }
        let values = points.filter { $0.date >= start && $0.date < limit }.map(\.value)
        guard values.count >= 3 else { return nil }
        return values.reduce(0, +) / Decimal(values.count)
    }
    static func unambiguousNights(_ points: [SleepPoint], excluding dates: Set<String> = []) -> [SleepPoint] {
        Dictionary(grouping: points, by: \.wakeDate).values.compactMap {
            $0.count == 1 && !dates.contains($0[0].wakeDate) ? $0[0] : nil
        }.sorted { $0.wakeDate < $1.wakeDate }
    }
    static func nights(_ points: [SleepPoint], endingOn day: String, days: Int) -> [SleepPoint] {
        guard let end = ProgressRules.civilDate(day),
              let start = ProgressRules.calendar("GMT").date(byAdding: .day, value: -(days - 1), to: end) else { return [] }
        let first = ProgressRules.day(start, timezoneID: "GMT")
        return unambiguousNights(points).filter { $0.wakeDate >= first && $0.wakeDate <= day }
    }
    static func sleepMean(_ points: [SleepPoint], endingOn day: String, days: Int) -> TimeInterval? {
        let p = nights(points, endingOn: day, days: days)
        guard p.count >= (days == 30 ? 12 : 4) else { return nil }
        return p.reduce(0) { $0 + $1.duration } / Double(p.count)
    }
    static func awakeningMean(_ points: [SleepPoint]) -> Double? {
        let values = unambiguousNights(points).compactMap(\.awakenings)
        guard values.count >= 5 else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
    static func clockMeans(_ points: [SleepPoint]) -> [String: (start: Double, end: Double)] {
        let groups = Dictionary(grouping: unambiguousNights(points)) { $0.startTimezoneID + " → " + $0.endTimezoneID }
        return groups.compactMapValues { p in
            guard p.count >= 7,
                  let start = ProgressRules.circularMean(p.map { ProgressRules.clockMinutes($0.start, timezoneID: $0.startTimezoneID) }),
                  let end = ProgressRules.circularMean(p.map { ProgressRules.clockMinutes($0.end, timezoneID: $0.endTimezoneID) }) else { return nil }
            return (start, end)
        }
    }
}
