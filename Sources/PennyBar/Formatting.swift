import Foundation
import PennyBarCore

enum AppLocale {
    /// The app's UI language with the user's region settings. Formatting with plain `Locale.current`
    /// would mix languages, e.g. "Updated 4分钟前" in an English UI.
    static let current: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(
            identifier: Bundle.main.preferredLocalizations.first ?? "en"
        )
        return Locale(components: components)
    }()
}

extension Money {
    private var style: Decimal.FormatStyle.Currency {
        // Narrow presentation shows "$" rather than "US$" outside the US.
        .currency(code: currency).presentation(.narrow).locale(AppLocale.current)
    }

    var formatted: String {
        amount.formatted(style)
    }

    /// Whole units once the amount reaches 100, to keep the menu bar narrow.
    var formattedCompact: String {
        amount.formatted(style.precision(.fractionLength(amount >= 100 ? 0 : 2)))
    }
}

extension LineItem {
    /// The name without a trailing parenthetical, e.g. "Workers CPU ms (first 30M are included)"
    /// becomes "Workers CPU ms". The full name is shown as a tooltip.
    var shortName: String {
        guard let open = name.firstIndex(of: "("), open > name.startIndex else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }

    var formattedQuantity: String? {
        guard let quantity else { return nil }
        let number = quantity.formatted(
            .number.notation(.compactName).precision(.significantDigits(1...3)).locale(AppLocale.current)
        )
        return [number, unit].compactMap { $0 }.joined(separator: " ")
    }
}

extension Date {
    /// "4 minutes ago", "yesterday".
    var relativeDescription: String {
        formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: AppLocale.current))
    }

    /// "Nov 2".
    var dayDescription: String {
        formatted(Date.FormatStyle(locale: AppLocale.current).month(.abbreviated).day())
    }
}

extension BillingPeriod {
    /// "Resets in 20 days", phrased around the next cycle start.
    func resetDescription(at now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: effectiveEnd)).day ?? 0
        return switch days {
        case ...0: "Resets today"
        case 1: "Resets tomorrow"
        default: "Resets in \(days) days"
        }
    }
}
