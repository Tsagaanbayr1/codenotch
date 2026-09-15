import Foundation
import SwiftUI

/// The latest completed native Ollama response, not a quota or a PC health score.
struct LocalModelPerformance: Equatable {
    let outputTokens: Int
    let generationSeconds: TimeInterval
    let measuredAt: Date
    /// The clock was ours, not the runtime's: the generating phase as polled,
    /// against the runtime's token count. A tilde marks it wherever it prints.
    let isApproximate: Bool

    init?(outputTokens: Int, durationNanoseconds: Int64, measuredAt: Date = Date(),
          isApproximate: Bool = false) {
        guard outputTokens > 0, durationNanoseconds > 0 else { return nil }
        self.outputTokens = outputTokens
        generationSeconds = Double(durationNanoseconds) / 1_000_000_000
        self.measuredAt = measuredAt
        self.isApproximate = isApproximate
    }

    /// LM Studio reports seconds as a floating-point count.
    init?(outputTokens: Int, seconds: TimeInterval, measuredAt: Date = Date(),
          isApproximate: Bool = false) {
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000_000 else { return nil }
        self.init(outputTokens: outputTokens, durationNanoseconds: Int64(seconds * 1_000_000_000),
                  measuredAt: measuredAt, isApproximate: isApproximate)
    }

    /// From the runtime's own rate, when that is what it reported.
    init?(outputTokens: Int, tokensPerSecond: Double, measuredAt: Date = Date()) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0, outputTokens > 0 else { return nil }
        self.init(outputTokens: outputTokens, seconds: Double(outputTokens) / tokensPerSecond,
                  measuredAt: measuredAt)
    }

    var fidelity: Fidelity { .derived }
    var tokensPerSecond: Double { Double(outputTokens) / generationSeconds }
    private var qualifier: String { isApproximate ? "~" : "" }
    var speedText: String { speedText(locale: L10n.locale) }

    /// `~` marks a speed Codenotch timed itself rather than one the runtime
    /// reported. A symbol, not a word, so it needs no translation.
    func speedText(locale: Locale = L10n.locale) -> String {
        guard tokensPerSecond >= 0.1 else {
            return qualifier + L10n.t("<0.1 tok/s", locale: locale)
        }
        let value = tokensPerSecond.formatted(
            .number.precision(.fractionLength(0...1)).locale(locale))
        return qualifier + L10n.t("\(value) tok/s", locale: locale)
    }

    var headlineText: String { headlineText(locale: L10n.locale) }

    /// The ring's own line, so the unit is the short one past a thousand.
    func headlineText(locale: Locale = L10n.locale) -> String {
        guard tokensPerSecond >= 1 else { return qualifier + L10n.t("<1 tok/s", locale: locale) }
        let value = tokensPerSecond.formatted(.number.notation(.compactName)
            .precision(.significantDigits(1...(tokensPerSecond >= 1000 ? 2 : 3)))
            .locale(locale))
        return qualifier + (tokensPerSecond >= 1000
            ? L10n.t("\(value) t/s", locale: locale)
            : L10n.t("\(value) tok/s", locale: locale))
    }

    enum Band: Equatable {
        case veryFast, smooth, slow, verySlow

        var label: String { label(locale: L10n.locale) }

        func label(locale: Locale = L10n.locale) -> String {
            switch self {
            case .veryFast: return L10n.t("Very fast", locale: locale)
            case .smooth:   return L10n.t("Smooth", locale: locale)
            case .slow:     return L10n.t("Slow", locale: locale)
            case .verySlow: return L10n.t("Very slow", locale: locale)
            }
        }
        var color: Color {
            switch self {
            case .veryFast: return Palette.generationFast
            case .smooth: return Palette.ample
            case .slow: return Palette.watch
            case .verySlow: return Palette.generationSlow
            }
        }
    }

    var band: Band {
        switch tokensPerSecond {
        case ..<10: return .verySlow
        case ..<20: return .slow
        case ..<40: return .smooth
        default:    return .veryFast
        }
    }

    static func parse(_ item: [String: Any], now: Date = Date()) -> LocalModelPerformance? {
        guard item["done"] as? Bool == true, item["error"] == nil,
              let count = positiveInteger(item["eval_count"]),
              let duration = positiveInteger(item["eval_duration"]),
              let tokens = Int(exactly: count) else { return nil }
        return LocalModelPerformance(outputTokens: tokens, durationNanoseconds: duration, measuredAt: now)
    }

    private static func positiveInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Int64(string) rejects overflow, fractions and non-finite JSON numbers.
        guard let integer = Int64(number.stringValue), integer > 0 else { return nil }
        return integer
    }
}
