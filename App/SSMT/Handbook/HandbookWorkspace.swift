import AppKit
import SSMTCore
import SwiftUI

extension Localizer {
    /// Content language of the handbook: follows the interface language.
    var russian: Bool {
        switch language {
        case .ru: return true
        case .en: return false
        case .system: return Bundle.main.preferredLocalizations.first?.hasPrefix("ru") ?? false
        }
    }
}

/// Selection shared by the sidebar and the workspace, remembered between launches.
enum HandbookPrefs {
    static let category = "ssmt.handbook.category"
    static let item = "ssmt.handbook.item"
    static let favorites = "ssmt.handbook.favorites"
    /// Pseudo-category: the starred pages.
    static let favoritesCategory = "favorites"

    static func favoriteIDs(_ raw: String) -> [String] { raw.split(separator: ",").map(String.init) }
}

/// A page of the handbook: an article or a calculator.
struct HandbookEntry: Identifiable {
    enum Kind {
        case article(HandbookArticle)
        case calculator(AudioCalculator)
    }
    var kind: Kind

    var id: String {
        switch kind {
        case .article(let a): return a.id
        case .calculator(let c): return "calc." + c.id
        }
    }

    var category: HandbookCategory {
        switch kind {
        case .article(let a): return a.category
        case .calculator: return .calculators
        }
    }

    var icon: String {
        switch kind {
        case .article(let a): return a.category.icon
        case .calculator(let c): return c.icon
        }
    }

    func title(_ ru: Bool) -> String {
        switch kind {
        case .article(let a): return a.title.text(russian: ru)
        case .calculator(let c): return c.title.text(russian: ru)
        }
    }

    func subtitle(_ ru: Bool) -> String {
        switch kind {
        case .article(let a): return a.subtitle.text(russian: ru)
        case .calculator(let c): return c.subtitle.text(russian: ru)
        }
    }
}

enum HandbookIndex {
    static let all: [HandbookEntry] =
        AudioCalculator.all.map { HandbookEntry(kind: .calculator($0)) } + Handbook.articles.map { HandbookEntry(kind: .article($0)) }

    static func entry(_ id: String) -> HandbookEntry? { all.first { $0.id == id } }

    /// Pages of a category, or search results across everything while a query is typed.
    static func entries(category: String, query: String, russian: Bool, favorites: [String]) -> [HandbookEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return AudioCalculator.search(q, russian: russian).map { HandbookEntry(kind: .calculator($0)) }
                + Handbook.search(q, russian: russian).map { HandbookEntry(kind: .article($0)) }
        }
        if category == HandbookPrefs.favoritesCategory { return favorites.compactMap(entry) }
        switch HandbookCategory(rawValue: category) ?? .calculators {
        case .calculators: return AudioCalculator.all.map { HandbookEntry(kind: .calculator($0)) }
        case .glossary:
            return Handbook.articles(in: .glossary).map { HandbookEntry(kind: .article($0)) }
                .sorted { $0.title(russian).localizedCaseInsensitiveCompare($1.title(russian)) == .orderedAscending }
        case let c: return Handbook.articles(in: c).map { HandbookEntry(kind: .article($0)) }
        }
    }

    static func count(_ category: HandbookCategory) -> Int {
        category == .calculators ? AudioCalculator.all.count : Handbook.articles(in: category).count
    }
}

// MARK: - Sidebar

/// Categories of function #5 in the app sidebar.
struct HandbookSidebarItems: View {
    @EnvironmentObject var loc: Localizer
    @AppStorage(HandbookPrefs.category) private var category = HandbookCategory.calculators.rawValue
    @AppStorage(HandbookPrefs.favorites) private var favoritesRaw = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HandbookCategory.allCases) { c in
                row(c.rawValue, icon: c.icon, title: c.title.text(russian: loc.russian), count: HandbookIndex.count(c))
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 8)
            row(HandbookPrefs.favoritesCategory, icon: "star", title: loc.t("hb.favorites"),
                count: HandbookPrefs.favoriteIDs(favoritesRaw).count)
        }
        .padding(.horizontal, 10)
    }

    private func row(_ id: String, icon: String, title: String, count: Int) -> some View {
        let on = category == id
        return Button { category = id } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 22)
                    .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)").font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workspace

/// Function #5: list of pages on the left, the page on the right, search on top (⌘F).
struct HandbookWorkspace: View {
    @EnvironmentObject var loc: Localizer
    @AppStorage(HandbookPrefs.category) private var category = HandbookCategory.calculators.rawValue
    @AppStorage(HandbookPrefs.item) private var itemID = ""
    @AppStorage(HandbookPrefs.favorites) private var favoritesRaw = ""
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var favorites: [String] { HandbookPrefs.favoriteIDs(favoritesRaw) }

    var body: some View {
        let ru = loc.russian
        let list = HandbookIndex.entries(category: category, query: query, russian: ru, favorites: favorites)
        let selected = list.first { $0.id == itemID } ?? list.first
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                HandbookList(entries: list, selectedID: selected?.id, searching: !query.isEmpty, russian: ru) { itemID = $0 }
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .glassCard(padding: 8)
                Group {
                    if let selected {
                        HandbookPage(entry: selected, russian: ru, favorite: favorites.contains(selected.id)) { toggleFavorite(selected.id) }
                            .id(selected.id)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glassCard(padding: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .background {
            // ⌘F — search.
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: [.command]).opacity(0).frame(width: 0, height: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("hb.title")).font(.system(size: 30, weight: .bold))
                Text(loc.t("section.handbook.subtitle")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField(loc.t("hb.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = HandbookIndex.entries(category: category, query: query, russian: loc.russian, favorites: favorites).first {
                            itemID = first.id
                        }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                        .help(loc.t("hb.clear"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Color.white.opacity(0.1)))
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: category == HandbookPrefs.favoritesCategory && query.isEmpty ? "star" : "magnifyingglass")
                .font(.system(size: 30)).foregroundStyle(Theme.textMuted)
            Text(category == HandbookPrefs.favoritesCategory && query.isEmpty ? loc.t("hb.favorites.empty") : loc.t("hb.nothing"))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleFavorite(_ id: String) {
        var f = favorites
        if let i = f.firstIndex(of: id) { f.remove(at: i) } else { f.append(id) }
        favoritesRaw = f.joined(separator: ",")
    }
}

/// The list of pages (category or search results).
struct HandbookList: View {
    @EnvironmentObject var loc: Localizer
    var entries: [HandbookEntry]
    var selectedID: String?
    var searching: Bool
    var russian: Bool
    var select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if searching {
                    Text(loc.t("hb.results", entries.count))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(entries) { e in
                    row(e)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
    }

    private func row(_ e: HandbookEntry) -> some View {
        let on = e.id == selectedID
        return Button { select(e.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: e.icon).font(.system(size: 13))
                    .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title(russian)).font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(searching ? e.category.title.text(russian: russian) + " · " + e.subtitle(russian) : e.subtitle(russian))
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One page: title row with the star, then the calculator or the article.
struct HandbookPage: View {
    @EnvironmentObject var loc: Localizer
    var entry: HandbookEntry
    var russian: Bool
    var favorite: Bool
    var toggleFavorite: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemName: entry.icon, tint: Theme.accent, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title(russian)).font(Theme.heading(22)).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Text(entry.subtitle(russian)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(action: toggleFavorite) {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .font(.system(size: 16))
                            .foregroundStyle(favorite ? Theme.signalYellow : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(loc.t(favorite ? "hb.removeFavorite" : "hb.addFavorite"))
                }
                switch entry.kind {
                case .calculator(let c): CalculatorView(calculator: c, russian: russian)
                case .article(let a): ArticleView(article: a, russian: russian)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}
