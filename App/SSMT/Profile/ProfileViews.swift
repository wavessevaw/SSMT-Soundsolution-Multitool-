import SSMTCore
import SwiftUI

extension AchievementRarity {
    var color: Color {
        switch self {
        case .common: return Color(hex: 0xA3ACA6)
        case .rare: return Color(hex: 0x64D2FF)
        case .epic: return Color(hex: 0xC79BFF)
        case .legendary: return Color(hex: 0xF0C24B)
        }
    }
}

extension AchievementCategory {
    var icon: String {
        switch self {
        case .general: return "sparkles"
        case .time: return "clock"
        case .setup: return "dial.medium"
        case .ptch: return "list.bullet.rectangle"
        case .qtrl: return "play.rectangle.on.rectangle"
        case .foh: return "slider.vertical.3"
        case .handbook: return "book"
        case .levels: return "chart.line.uptrend.xyaxis"
        case .secrets: return "eye"
        }
    }
}

private func formatInt(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = " "
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

private func formatHours(_ h: Double) -> String {
    h < 10 ? String(format: "%.1f", h) : "\(Int(h))"
}

// MARK: - Sidebar badge

/// Under the logo in the sidebar: avatar, rank and level, XP bar; opens the profile.
struct ProfileBadge: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let p = center.current {
            let pr = p.progress
            let level = pr.computedLevel
            let rank = EngineerRank.of(level: level)
            let next = pr.nextLevel
            Button { center.showProfile = true } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ProfileAvatar(initials: p.initials, color: p.color, level: level, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(rank.name.text(russian: loc.russian) + " · " + loc.t("acc.levelShort", level))
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(rank.textColor)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            Image(systemName: "trophy").font(.system(size: 10, weight: .bold))
                            Text("\(pr.unlocked.count)").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Color(hex: 0xF6D57D))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: 0xF0C24B).opacity(0.12)))
                    }
                    XPBar(fraction: next?.overall ?? 1, color: rank.color, height: 6)
                    if let next {
                        Text(loc.t("acc.toLevel", next.level, Int((next.overall * 100).rounded())))
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(loc.t("acc.openProfile"))
        }
    }
}

// MARK: - Profile window

struct ProfileSheet: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $tab) {
                    Text(loc.t("acc.tab.profile")).tag(0)
                    Text(loc.t("acc.tab.achievements")).tag(1)
                    Text(loc.t("acc.tab.levels")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 380)
                Spacer()
                Button(loc.t("acc.logout")) { center.logout() }.buttonStyle(SSMTButtonStyle())
                Button(loc.t("settings.done")) { center.showProfile = false }
                    .buttonStyle(SSMTButtonStyle(kind: .primary)).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider().opacity(0.3)
            ScrollView {
                Group {
                    switch tab {
                    case 1: AchievementWall()
                    case 2: LevelTable()
                    default: ProfileOverview()
                    }
                }
                .padding(28)
            }
        }
        .frame(width: 1100, height: 760)
        .background(Backdrop())
        .preferredColorScheme(.dark)
    }
}

struct ProfileOverview: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let p = center.current {
            let pr = p.progress
            let level = pr.computedLevel
            let rank = EngineerRank.of(level: level)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    header(p, pr: pr, level: level, rank: rank)
                    xpSources
                }
                ladder(level)
                stats(pr)
                recent(pr)
            }
        }
    }

    private func header(_ p: LocalProfile, pr: PlayerProgress, level: Int, rank: EngineerRank) -> some View {
        HStack(spacing: 26) {
            ProfileAvatar(initials: p.initials, color: p.color, level: level, size: 116)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.system(size: 28, weight: .heavy))
                    Text(rank.name.text(russian: loc.russian) + " · " + loc.t("acc.level", level) + " · " + rank.title.text(russian: loc.russian))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(rank.textColor)
                }
                if let next = pr.nextLevel {
                    HStack {
                        Text(loc.t("acc.toLevelPlain", next.level)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(formatInt(pr.xp)) / \(formatInt(Leveling.xpRequired(next.level))) XP").font(Theme.mono(13))
                    }
                    XPBar(fraction: next.overall, color: rank.color, height: 14)
                    HStack(spacing: 18) {
                        condition(done: next.hours >= 1, icon: "clock",
                                  text: loc.t("acc.cond.hours", formatHours(pr.hours), formatHours(Leveling.hoursRequired(next.level))))
                        condition(done: next.clicks >= 1, icon: "cursorarrow.click",
                                  text: loc.t("acc.cond.clicks", formatInt(pr.clicks), formatInt(Leveling.clicksRequired(next.level))))
                    }
                } else {
                    Text(loc.t("acc.maxLevel")).font(.system(size: 14, weight: .bold)).foregroundStyle(EngineerRank.gold.textColor)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.08)))
    }

    private func condition(done: Bool, icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark" : icon).font(.system(size: 12, weight: .bold))
                .foregroundStyle(done ? Theme.accent : Theme.signalYellow)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var xpSources: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(loc.t("acc.xpFrom")).font(.system(size: 11, weight: .bold)).tracking(1.1).foregroundStyle(Theme.textSecondary)
            source("acc.xp.hour", "+100")
            source("acc.xp.click", "+1")
            source("acc.xp.delay", "+20")
            source("acc.xp.setup", "+150")
            source("acc.xp.show", "+200")
            source("acc.xp.soundcheck", "+150")
            source("acc.xp.achievement", "+50…500")
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.08)))
    }

    private func source(_ key: String, _ xp: String) -> some View {
        HStack {
            Text(loc.t(key)).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            Spacer()
            Text(xp).font(Theme.mono(12)).foregroundStyle(Theme.accent)
        }
    }

    private func ladder(_ level: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(loc.t("acc.pathToGold")).font(.system(size: 15, weight: .heavy))
                Spacer()
                Text(loc.t("acc.level40")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                ForEach(EngineerRank.allCases, id: \.self) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(Array(r.levels), id: \.self) { l in
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(l <= level ? r.color : Color(hex: 0x1F2421))
                                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(l == level + 1 ? r.color : Color.clear))
                                    .frame(height: 12)
                            }
                        }
                        Text(r.name.text(russian: loc.russian) + " \(r.levels.lowerBound)–\(r.levels.upperBound) · " + r.title.text(russian: loc.russian))
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(r.textColor).lineLimit(1)
                    }
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.08)))
    }

    private func stats(_ pr: PlayerProgress) -> some View {
        HStack(spacing: 12) {
            stat(formatHours(pr.hours), "acc.stat.hours")
            stat(formatInt(pr.clicks), "acc.stat.clicks")
            stat(formatInt(pr.counters["qtrl.go", default: 0]), "acc.stat.go")
            stat(formatInt(pr.counters["setup.finished", default: 0]), "acc.stat.setups")
            stat("\(pr.unlocked.count) / \(AchievementCatalog.all.count)", "acc.stat.achievements", gold: true)
        }
    }

    private func stat(_ value: String, _ key: String, gold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.mono(24, weight: .bold)).foregroundStyle(gold ? Color(hex: 0xF6D57D) : Theme.textPrimary)
            Text(loc.t(key)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(gold ? Color(hex: 0xF0C24B).opacity(0.08) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(gold ? Color(hex: 0xF0C24B).opacity(0.35) : Color.white.opacity(0.08)))
    }

    private func recent(_ pr: PlayerProgress) -> some View {
        let last = pr.unlocked.sorted { $0.value > $1.value }.prefix(3).compactMap { AchievementCatalog.achievement($0.key) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("acc.recent")).font(.system(size: 15, weight: .heavy))
            HStack(spacing: 12) {
                ForEach(last) { a in
                    AchievementRow(achievement: a, date: pr.unlocked[a.id])
                }
                AchievementRow(achievement: nil, hiddenCount: AchievementCatalog.all.count - pr.unlocked.count)
            }
        }
    }
}

/// Compact card of the profile page.
struct AchievementRow: View {
    @EnvironmentObject var loc: Localizer
    var achievement: Achievement?
    var date: Date? = nil
    var hiddenCount = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: achievement?.category.icon ?? "lock")
                .font(.system(size: 17))
                .foregroundStyle(achievement?.rarity.color ?? Theme.textMuted)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(achievement == nil ? Theme.panelRaised : (achievement!.rarity.color.opacity(0.14))))
            VStack(alignment: .leading, spacing: 2) {
                if let a = achievement {
                    Text(a.title.text(russian: loc.russian)).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text("+\(a.rarity.xp) XP").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(loc.t("acc.hiddenLeft", hiddenCount)).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    Text(loc.t("acc.keepWorking")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(achievement == nil ? 0.14 : 0.08), style: StrokeStyle(lineWidth: 1, dash: achievement == nil ? [4, 3] : [])))
    }
}

// MARK: - Achievement wall

struct AchievementWall: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer
    @State private var filter = 0
    @State private var category: AchievementCategory?

    var body: some View {
        let pr = center.progress
        let earned = AchievementCatalog.all.filter { pr.unlocked[$0.id] != nil }.reduce(0) { $0 + $1.rarity.xp }
        let list = AchievementCatalog.all.filter { a in
            let open = pr.unlocked[a.id] != nil
            let inProgress = !open && (pr.value(for: a) ?? 0) > 0
            let kindOK = filter == 0 || (filter == 1 && open) || (filter == 2 && inProgress) || (filter == 3 && !open && !inProgress)
            return kindOK && (category == nil || a.category == category)
        }
        .sorted { (pr.unlocked[$0.id] != nil ? 0 : 1, $0.id) < (pr.unlocked[$1.id] != nil ? 0 : 1, $1.id) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("acc.tab.achievements")).font(.system(size: 26, weight: .heavy))
                    Text(loc.t("acc.opened", pr.unlocked.count, AchievementCatalog.all.count, formatInt(earned)))
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                XPBar(fraction: Double(pr.unlocked.count) / Double(AchievementCatalog.all.count), color: Color(hex: 0xF0C24B), height: 10)
                    .frame(width: 300)
            }
            HStack(spacing: 8) {
                chip("acc.f.all", on: filter == 0) { filter = 0 }
                chip("acc.f.open", on: filter == 1) { filter = 1 }
                chip("acc.f.progress", on: filter == 2) { filter = 2 }
                chip("acc.f.hidden", on: filter == 3) { filter = 3 }
                Divider().frame(height: 20)
                Picker("", selection: $category) {
                    Text(loc.t("acc.f.allCategories")).tag(AchievementCategory?.none)
                    ForEach(AchievementCategory.allCases, id: \.self) { c in
                        Text(c.name.text(russian: loc.russian)).tag(AchievementCategory?.some(c))
                    }
                }
                .labelsHidden().frame(width: 220)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(list) { a in AchievementCard(achievement: a, progress: pr) }
            }
        }
    }

    private func chip(_ key: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc.t(key)).font(.system(size: 13, weight: on ? .bold : .regular))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.14) : Theme.panel))
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.6) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Open, in progress, or hidden ("???" with a hint).
struct AchievementCard: View {
    @EnvironmentObject var loc: Localizer
    var achievement: Achievement
    var progress: PlayerProgress

    var body: some View {
        let a = achievement
        let date = progress.unlocked[a.id]
        let open = date != nil
        let value = progress.value(for: a) ?? 0
        let inProgress = !open && value > 0
        let shown = open || inProgress
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Image(systemName: shown ? a.category.icon : "lock")
                    .font(.system(size: 17))
                    .foregroundStyle(shown ? a.rarity.color : Theme.textMuted)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11).fill(open ? a.rarity.color.opacity(0.14) : Theme.panelRaised))
                Spacer()
                Text(shown ? a.rarity.name.text(russian: loc.russian) : "???")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(shown ? a.rarity.color : Theme.textMuted)
            }
            Text(shown ? a.title.text(russian: loc.russian) : "???")
                .font(.system(size: 14, weight: .heavy)).foregroundStyle(shown ? Theme.textPrimary : Theme.textMuted).lineLimit(2)
            Text(shown ? a.text.text(russian: loc.russian) : loc.t("acc.hidden") + " · " + a.category.name.text(russian: loc.russian))
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .top)
            if inProgress, let t = a.target {
                XPBar(fraction: value / t.value, color: a.rarity.color, height: 6)
                Text("\(formatInt(Int(value))) / \(formatInt(Int(t.value)))").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Group {
                if let date {
                    Text(loc.t("acc.gotOn", date.formatted(.dateTime.day().month().year().locale(loc.locale)), a.rarity.xp))
                } else if !shown, let hint = a.hint {
                    Text(loc.t("acc.hint", hint.text(russian: loc.russian)))
                } else if !shown {
                    Text(loc.t("acc.noHint"))
                } else {
                    Text(loc.t("acc.inProgress"))
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(shown ? Theme.panel : Color(hex: 0x0D100E)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
            a.rarity == .legendary && open ? a.rarity.color.opacity(0.45) : Color.white.opacity(shown ? 0.08 : 0.14),
            style: StrokeStyle(lineWidth: 1, dash: shown ? [] : [4, 3])))
    }
}

// MARK: - Levels

struct LevelTable: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let current = center.progress.computedLevel
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("acc.levelsTitle")).font(.system(size: 26, weight: .heavy))
            Text(loc.t("acc.levelsText")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    head("acc.col.level"); head("acc.col.rank"); head("acc.col.xp"); head("acc.col.hours"); head("acc.col.clicks")
                }
                .background(Color.white.opacity(0.06))
                ForEach(1...Leveling.maxLevel, id: \.self) { l in
                    let r = EngineerRank.of(level: l)
                    GridRow {
                        cell("\(l)", color: r.textColor, mono: true)
                        cell((l - 1) % 10 == 0 ? r.name.text(russian: loc.russian) : "", color: r.textColor)
                        cell(formatInt(Leveling.xpRequired(l)), mono: true)
                        cell(formatHours(Leveling.hoursRequired(l)), mono: true)
                        cell(formatInt(Leveling.clicksRequired(l)), mono: true)
                    }
                    .background(l == current ? r.color.opacity(0.14) : (l % 2 == 0 ? Color.white.opacity(0.02) : Color.clear))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
        }
    }

    private func head(_ key: String) -> some View {
        Text(loc.t(key)).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ s: String, color: Color = Theme.textPrimary, mono: Bool = false) -> some View {
        Text(s).font(mono ? Theme.mono(12) : .system(size: 12, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Toast and level up

/// "New achievement" card in the top-right corner; disappears by itself.
struct AchievementToast: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let id = center.toasts.first, let a = AchievementCatalog.achievement(id) {
            HStack(spacing: 14) {
                Image(systemName: a.category.icon).font(.system(size: 24)).foregroundStyle(a.rarity.color)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 15).fill(a.rarity.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("acc.newAchievement") + " · " + a.rarity.name.text(russian: loc.russian).uppercased())
                        .font(.system(size: 10, weight: .heavy)).tracking(1.1).foregroundStyle(a.rarity.color)
                    Text(a.title.text(russian: loc.russian)).font(.system(size: 17, weight: .heavy))
                    Text(a.text.text(russian: loc.russian)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    Text("+\(a.rarity.xp) XP").font(Theme.mono(14, weight: .bold)).foregroundStyle(Theme.accent)
                    Button { center.dismissToast() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help(loc.t("acc.close"))
                }
            }
            .padding(16)
            .frame(width: 470)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x161A17)))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(a.rarity.color.opacity(0.45)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(id)
            .task(id: id) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { if center.toasts.first == id { center.dismissToast() } }
            }
            .onTapGesture { center.showProfile = true }
        }
    }
}

struct LevelUpOverlay: View {
    @EnvironmentObject var center: ProfileCenter
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let level = center.levelUp {
            let rank = EngineerRank.of(level: level)
            let newRank = (level - 1) % 10 == 0
            let pr = center.progress
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { center.levelUp = nil }
                VStack(spacing: 16) {
                    Text(loc.t(newRank ? "acc.newRank" : "acc.newLevel")).font(.system(size: 12, weight: .heavy)).tracking(1.5).foregroundStyle(rank.textColor)
                    Text("\(level)").font(Theme.mono(46, weight: .bold)).foregroundStyle(rank.textColor)
                        .frame(width: 120, height: 120)
                        .background(Circle().fill(Theme.panelRaised))
                        .overlay(Circle().strokeBorder(rank.color, lineWidth: 7))
                    VStack(spacing: 6) {
                        Text(newRank ? rank.name.text(russian: loc.russian) + "!" : loc.t("acc.level", level))
                            .font(.system(size: 28, weight: .heavy))
                        Text(rank.name.text(russian: loc.russian) + " · " + loc.t("acc.level", level) + " · " + rank.title.text(russian: loc.russian))
                            .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(loc.t("acc.levelUpText", formatHours(pr.hours), formatInt(pr.clicks)))
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    if let next = pr.nextLevel {
                        VStack(spacing: 6) {
                            HStack {
                                Text(loc.t("acc.toLevelPlain", next.level))
                                Spacer()
                                Text("\(formatInt(pr.xp)) / \(formatInt(Leveling.xpRequired(next.level))) XP").font(Theme.mono(12))
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            XPBar(fraction: next.overall, color: rank.color, height: 8)
                        }
                    }
                    Button { center.levelUp = nil } label: {
                        Text(loc.t("acc.continue")).font(.system(size: 15, weight: .heavy)).foregroundStyle(Color(hex: 0x14110A))
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 12).fill(rank.color))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 24).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(rank.color.opacity(0.4)))
            }
            .transition(.opacity)
        }
    }
}
