import SSMTCore
import SwiftUI

extension EngineerRank {
    /// Ring / badge colour.
    var color: Color {
        switch self {
        case .copper: return Color(hex: 0xB5643A)
        case .bronze: return Color(hex: 0xC99A5B)
        case .silver: return Color(hex: 0xC9CED6)
        case .gold: return Color(hex: 0xF0C24B)
        }
    }

    /// Lighter tint for text on dark.
    var textColor: Color {
        switch self {
        case .copper: return Color(hex: 0xD08257)
        case .bronze: return Color(hex: 0xDDB27A)
        case .silver: return Color(hex: 0xE1E5EA)
        case .gold: return Color(hex: 0xF6D57D)
        }
    }
}

/// Round avatar with initials, a ring in the rank colour and the level on a small pill.
struct ProfileAvatar: View {
    var initials: String
    var color: Int
    var level: Int
    var size: CGFloat = 48
    var showLevel = true

    var body: some View {
        let rank = EngineerRank.of(level: level)
        ZStack(alignment: .bottomTrailing) {
            Text(initials)
                .font(.system(size: size * 0.32, weight: .heavy))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(hex: UInt32(color))))
                .overlay(Circle().strokeBorder(rank.color, lineWidth: max(2, size * 0.055)))
            if showLevel {
                Text("\(level)")
                    .font(Theme.mono(max(10, size * 0.22), weight: .bold))
                    .foregroundStyle(Color(hex: 0x101214))
                    .padding(.horizontal, size * 0.09)
                    .frame(minWidth: size * 0.46, minHeight: size * 0.42)
                    .background(Capsule().fill(rank.color))
                    .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: max(2, size * 0.04)))
                    .offset(x: size * 0.1, y: size * 0.06)
            }
        }
    }
}

/// Before the app: a small centred card with the logo — sign in to a profile on this Mac or create one.
struct AccountGate: View {
    @EnvironmentObject var center: ProfileCenter
    @State private var registering = false

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 28) {
                BrandMark(variant: .full, height: 96)
                Group {
                    if registering || center.profiles.isEmpty {
                        RegisterView(canGoBack: !center.profiles.isEmpty) { registering = false }
                    } else {
                        LoginView { registering = true }
                    }
                }
                .frame(width: 340)
            }
            .padding(.bottom, 40)
        }
        .preferredColorScheme(.dark)
    }
}

/// Plain input of the account card.
private struct AccountField: View {
    var placeholder: String
    @Binding var text: String
    var secure = false
    var failed = false

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(failed ? Theme.statusError.opacity(0.8) : Color.white.opacity(0.1)))
    }
}

private struct AccountButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Color(hex: 0x06140D))
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

struct LoginView: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer
    var createProfile: () -> Void
    @State private var selected: LocalProfile.ID?
    @State private var password = ""
    @State private var autoLogin = true
    @State private var failed = false
    @FocusState private var pwFocused: Bool

    private var profile: LocalProfile? { center.profiles.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 14) {
            if let p = profile {
                VStack(spacing: 8) {
                    Text(p.initials).font(.system(size: 21, weight: .heavy)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Color(hex: UInt32(p.color))))
                    if center.profiles.count > 1 {
                        Menu {
                            ForEach(center.profiles) { q in
                                Button(q.name) { selected = q.id; failed = false; password = "" }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(p.name).font(.system(size: 17, weight: .bold))
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(Theme.textPrimary)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    } else {
                        Text(p.name).font(.system(size: 17, weight: .bold))
                    }
                }
                .padding(.bottom, 6)
            }
            AccountField(placeholder: loc.t("acc.password"), text: $password, secure: true, failed: failed)
                .focused($pwFocused)
                .onSubmit(signIn)
            if failed {
                Text(loc.t("acc.err.wrongPassword")).font(.system(size: 12)).foregroundStyle(Theme.statusError)
            }
            AccountButton(title: loc.t("acc.signIn"), action: signIn)
            HStack {
                Toggle(loc.t("acc.auto"), isOn: $autoLogin).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Button(loc.t("acc.create"), action: createProfile).buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .onAppear {
            selected = selected ?? center.profiles.first?.id
            pwFocused = true
        }
    }

    private func signIn() {
        guard let id = selected else { return }
        do {
            try center.login(id, password: password, autoLogin: autoLogin)
        } catch {
            failed = true
            password = ""
        }
    }
}

struct RegisterView: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer
    var canGoBack: Bool
    var back: () -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var again = ""
    @State private var color = ProfileCenter.avatarColors[0]
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(loc.t("acc.newProfile")).font(.system(size: 17, weight: .bold))
            AccountField(placeholder: loc.t("acc.name"), text: $name)
            AccountField(placeholder: loc.t("acc.password"), text: $password, secure: true)
            AccountField(placeholder: loc.t("acc.again"), text: $again, secure: true)
            HStack(spacing: 10) {
                ForEach(ProfileCenter.avatarColors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Color(hex: UInt32(c))).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(color == c ? Theme.accent : Color.white.opacity(0.15), lineWidth: color == c ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(loc.t("acc.color"))
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.statusError).multilineTextAlignment(.center)
            }
            AccountButton(title: loc.t("acc.createStart"), action: create)
            if canGoBack {
                Button(loc.t("acc.backToLogin"), action: back).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func create() {
        do {
            try center.register(name: name, email: "", password: password, repeat: again, role: "foh", color: color, autoLogin: true)
        } catch let e as ProfileCenter.AccountError {
            error = loc.t("acc.err.\(e.rawValue)")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Experience bar.
struct XPBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x1F2421))
                Capsule().fill(color).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}
