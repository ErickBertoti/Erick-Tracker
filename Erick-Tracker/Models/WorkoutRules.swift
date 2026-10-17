import Foundation

nonisolated enum WorkoutRules {
    static let locale = Locale(identifier: "pt_BR")

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        let text = normalized(fields.joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func count(_ count: Int, singular: String, plural: String) -> String {
        count.formatted(.number.locale(locale)) + " " + (count == 1 ? singular : plural)
    }
    static func restText(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
    /// An empty field inherits its item's rest. A plain number means seconds.
    static func parseRest(_ text: String) -> Int? {
        let value = trimmed(text)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1, let seconds = Int(value), (0...59_999).contains(seconds) { return seconds }
        if parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
           minutes >= 0, (0..<60).contains(seconds), minutes <= 999 {
            return minutes * 60 + seconds
        }
        return nil
    }
    static func validIntensity(_ value: String) -> Bool {
        let text = trimmed(value)
        if text.isEmpty { return true }
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return false }
        return number.isFinite && (0...10).contains(number)
    }
}

nonisolated struct TrainingDefaults {
    var restSeconds = 120
    var intensityScale: IntensityScale = .rir
    var intensityTarget = "2"

    static func read(from defaults: UserDefaults = .standard) -> Self {
        let rest = defaults.object(forKey: "defaultRestSeconds") as? Int ?? 120
        let scale = IntensityScale(rawValue: defaults.string(forKey: "defaultIntensityScale") ?? "rir") ?? .rir
        let target = defaults.object(forKey: "defaultIntensityTarget") as? Double ?? 2
        return .init(restSeconds: max(0, min(900, rest)), intensityScale: scale,
                     intensityTarget: target.formatted(.number.locale(WorkoutRules.locale).precision(.fractionLength(0...1))))
    }
}
