import PennyBarCore
import SwiftUI

extension ProviderDescriptor {
    var tint: Color {
        guard let tintHex, let value = UInt32(tintHex, radix: 16) else { return .primary }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The provider's symbol on a soft tinted tile.
struct ProviderBadge: View {
    let descriptor: ProviderDescriptor?
    var size: CGFloat = 28

    var body: some View {
        let tint = descriptor?.tint ?? .secondary
        mark
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.3, style: .continuous))
    }

    @ViewBuilder
    private var mark: some View {
        let symbolName = descriptor?.symbolName ?? "questionmark"
        if let custom = ProviderMarks.image(for: symbolName) {
            // Sized to match the optical weight of the SF Symbols used for other providers.
            Image(nsImage: custom)
                .renderingMode(.template)
                .resizable()
                .frame(width: size * 0.5, height: size * 0.5)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size * 0.46, weight: .semibold))
        }
    }
}

/// Horizontal bar split into segments proportional to each value.
struct ShareBar: View {
    struct Segment: Identifiable {
        let id: UUID
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let available = geometry.size.width - spacing * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(available * segment.value / max(total, .ulpOfOne), 2))
                }
            }
        }
        .frame(height: height)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

extension BudgetStatus {
    /// Bar color: the provider tint while normal, amber from 80% (matching the menu bar icon), red once reached.
    func color(normal: Color) -> Color {
        switch self {
        case .normal: normal
        case .warning: Color(nsColor: MenuBarIcon.warningFill)
        case .exceeded: .red
        }
    }
}

/// Spend against a cap, used for both user budgets and provider usage limits.
struct BudgetBar: View {
    let title: String
    let spent: Money
    let limit: Decimal
    let tint: Color

    private var status: BudgetStatus { BudgetStatus(spent: spent, budget: limit) }

    private var fraction: Double { Self.fraction(spent: spent, limit: limit) }

    static func fraction(spent: Money, limit: Decimal) -> Double {
        guard limit > 0 else { return 0 }
        return NSDecimalNumber(decimal: spent.amount / limit).doubleValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                if status == .warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BudgetStatus.warning.color(normal: .secondary))
                } else if status == .exceeded {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("\(spent.formatted) of \(Money(limit, currency: spent.currency).formatted)")
                    .monospacedDigit()
                    .foregroundStyle(status == .exceeded ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            BudgetProgress(fraction: fraction, color: status.color(normal: tint))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin capsule filled up to `fraction`, capped at full.
struct BudgetProgress: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Currency entry for an optional budget; clearing the field removes the budget.
struct BudgetField: View {
    let title: String
    @Binding var value: Decimal?

    var body: some View {
        TextField(
            title,
            value: $value,
            format: .currency(code: "USD").presentation(.narrow).locale(AppLocale.current),
            prompt: Text("No budget")
        )
    }
}

/// Shows a cost, prefixing estimates with "≈" so they read differently from billed amounts.
struct CostText: View {
    let money: Money?
    let kind: CostKind

    var body: some View {
        if let money {
            Text((kind == .estimated ? "≈ " : "") + money.formatted)
                .monospacedDigit()
                .help(kind == .estimated ? "Estimated from usage and published prices" : "Reported by the provider")
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

/// Row background that highlights on hover, like a native menu item.
struct HoverHighlight: ViewModifier {
    var isActive = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                .quaternary.opacity(isActive ? 0.7 : isHovering ? 0.5 : 0),
                in: .rect(cornerRadius: 8, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(isActive: Bool = false) -> some View {
        modifier(HoverHighlight(isActive: isActive))
    }
}
