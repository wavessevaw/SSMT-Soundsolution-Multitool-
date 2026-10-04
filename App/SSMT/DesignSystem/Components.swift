import SwiftUI

/// Dark backdrop with two soft warm glows, shared by all windows.
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0E1210), Color(hex: 0x050706)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.12), .clear], center: UnitPoint(x: 0.85, y: -0.05),
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Theme.accentHot.opacity(0.08), .clear], center: UnitPoint(x: 0.05, y: 1.05),
                           startRadius: 0, endRadius: 650)
        }
        .ignoresSafeArea()
    }
}

/// Frosted glass surface: translucent fill, top highlight hairline, soft shadow.
struct GlassBackground: View {
    var radius: CGFloat = Theme.radius
    var highlighted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Color.white.opacity(highlighted ? 0.09 : 0.045))
            .background(shape.fill(Color(hex: 0x111513).opacity(0.55)))
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(highlighted ? 0.22 : 0.12), Color.white.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .softShadow(.black.opacity(0.35), radius: 18, y: 8)
    }
}

extension View {
    /// Places the view on a glass card.
    func glassCard(padding: CGFloat = 18, radius: CGFloat = Theme.radius, highlighted: Bool = false) -> some View {
        self.padding(padding).background(GlassBackground(radius: radius, highlighted: highlighted))
    }

    /// `plain`: no card at all (the view sits inside another card).
    @ViewBuilder func glassCard(padding: CGFloat, plain: Bool) -> some View {
        if plain { self.padding(padding) } else { self.glassCard(padding: padding) }
    }
}

/// Glass card with an optional title marked by a short coloured bar.
struct Panel<Content: View>: View {
    var title: String?
    var marking: String?
    var tint: Color = Theme.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || marking != nil {
                CardTitle(title: title ?? "", marking: marking, tint: tint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct CardTitle: View {
    var title: String
    var marking: String? = nil
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 15)
            Text(title).font(Theme.heading(15)).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let marking {
                Text(marking).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Rounded square with an SF Symbol, used in list rows.
struct IconTile: View {
    var systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Round check mark: empty ring → filled accent check.
struct CheckDot: View {
    var done: Bool
    var failed = false

    var body: some View {
        ZStack {
            if done {
                Circle().fill(Theme.statusGood)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
            } else if failed {
                Circle().fill(Theme.statusError)
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.2), value: done)
    }
}

enum SSMTButtonKind { case primary, secondary, danger }

struct SSMTButtonStyle: ButtonStyle {
    var kind: SSMTButtonKind = .secondary
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: kind == .secondary ? .regular : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(fill(shape))
            .overlay(shape.strokeBorder(Color.white.opacity(kind == .secondary ? 0.12 : 0.18), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return active ? Theme.accent : Theme.textPrimary
        case .danger: return .white
        }
    }

    @ViewBuilder private func fill(_ shape: RoundedRectangle) -> some View {
        switch kind {
        case .primary: shape.fill(LinearGradient(colors: [Theme.accent, Theme.accentHot], startPoint: .leading, endPoint: .trailing))
        case .secondary: shape.fill(active ? Theme.accent.opacity(0.18) : Color.white.opacity(0.07))
        case .danger: shape.fill(Theme.statusError)
        }
    }
}

enum StatusLevel { case good, warning, error, idle }

/// Status label: small icon + word + colour (never colour alone).
struct StatusBadge: View {
    var level: StatusLevel
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var icon: String {
        switch level {
        case .good: return "checkmark"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "minus"
        }
    }

    private var color: Color {
        switch level {
        case .good: return Theme.statusGood
        case .warning: return Theme.statusWarning
        case .error: return Theme.statusError
        case .idle: return Theme.textMuted
        }
    }
}

/// Slim input meter (−60…0 dBFS) with a peak tick and a clip label.
struct MeterBar: View {
    var label: String
    var rmsDBFS: Double
    var peakDBFS: Double
    var clipped: Bool
    var clipText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Theme.label(12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "%.1f dBFS", rmsDBFS)).font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
                if clipped {
                    Text(clipText).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.statusError)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(clipped ? Theme.statusError : Theme.textPrimary.opacity(0.85))
                        .frame(width: max(4, w * fraction(rmsDBFS)))
                    Capsule().fill(Theme.textPrimary).frame(width: 2).offset(x: w * fraction(peakDBFS) - 1)
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.12), value: rmsDBFS)
        }
    }

    private func fraction(_ db: Double) -> CGFloat {
        CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}

/// Hairline divider.
struct TechDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}
