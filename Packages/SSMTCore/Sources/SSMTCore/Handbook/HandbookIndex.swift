import Foundation

/// A page of the handbook: an article or a calculator.
public struct HandbookEntry: Identifiable, Sendable {
    public enum Kind: Sendable {
        case article(HandbookArticle)
        case calculator(AudioCalculator)
    }
    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var id: String {
        switch kind {
        case .article(let a): return a.id
        case .calculator(let c): return "calc." + c.id
        }
    }

    public var category: HandbookCategory {
        switch kind {
        case .article(let a): return a.category
        case .calculator: return .calculators
        }
    }

    public var icon: String {
        switch kind {
        case .article(let a): return a.category.icon
        case .calculator(let c): return c.icon
        }
    }

    public func title(_ ru: Bool) -> String {
        switch kind {
        case .article(let a): return a.title.text(russian: ru)
        case .calculator(let c): return c.title.text(russian: ru)
        }
    }

    public func subtitle(_ ru: Bool) -> String {
        switch kind {
        case .article(let a): return a.subtitle.text(russian: ru)
        case .calculator(let c): return c.subtitle.text(russian: ru)
        }
    }
}

/// Every page of the handbook, the pages of a category and search across everything.
public enum HandbookIndex {
    /// Pseudo-category: the starred pages.
    public static let favoritesCategory = "favorites"

    public static let all: [HandbookEntry] =
        AudioCalculator.all.map { HandbookEntry(kind: .calculator($0)) } + Handbook.articles.map { HandbookEntry(kind: .article($0)) }

    public static func entry(_ id: String) -> HandbookEntry? { all.first { $0.id == id } }

    /// Pages of a category, or search results across everything while a query is typed.
    public static func entries(category: String, query: String, russian: Bool, favorites: [String]) -> [HandbookEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return AudioCalculator.search(q, russian: russian).map { HandbookEntry(kind: .calculator($0)) }
                + Handbook.search(q, russian: russian).map { HandbookEntry(kind: .article($0)) }
        }
        if category == favoritesCategory { return favorites.compactMap(entry) }
        switch HandbookCategory(rawValue: category) ?? .calculators {
        case .calculators: return AudioCalculator.all.map { HandbookEntry(kind: .calculator($0)) }
        case .glossary:
            return Handbook.articles(in: .glossary).map { HandbookEntry(kind: .article($0)) }
                .sorted { $0.title(russian).localizedCaseInsensitiveCompare($1.title(russian)) == .orderedAscending }
        case let c: return Handbook.articles(in: c).map { HandbookEntry(kind: .article($0)) }
        }
    }

    public static func count(_ category: HandbookCategory) -> Int {
        category == .calculators ? AudioCalculator.all.count : Handbook.articles(in: category).count
    }
}
