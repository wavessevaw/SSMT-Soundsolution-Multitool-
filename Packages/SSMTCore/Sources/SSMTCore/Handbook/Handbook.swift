import Foundation

/// Function #5: the handbook — consoles, glossary, how-to guides for sound tasks, cable pinouts and calculators.
/// Content is written for the app (no copied manuals) in Russian and English.

/// A text in both interface languages.
public struct LText: Hashable, Sendable {
    public var ru: String
    public var en: String
    public init(_ ru: String, _ en: String) {
        self.ru = ru
        self.en = en
    }
    /// Same text in both languages (model names, units, formulas).
    public init(_ both: String) {
        ru = both
        en = both
    }
    public func text(russian: Bool) -> String { russian ? ru : en }
}

public enum HandbookCategory: String, CaseIterable, Identifiable, Sendable {
    case calculators, pinouts, guides, consoles, glossary
    public var id: String { rawValue }

    public var title: LText {
        switch self {
        case .calculators: return LText("Калькуляторы", "Calculators")
        case .pinouts: return LText("Распайки", "Pinouts")
        case .guides: return LText("Инструкции", "How-to guides")
        case .consoles: return LText("Пульты", "Consoles")
        case .glossary: return LText("Термины", "Glossary")
        }
    }

    public var icon: String {
        switch self {
        case .calculators: return "function"
        case .pinouts: return "cable.connector"
        case .guides: return "list.bullet.clipboard"
        case .consoles: return "slider.horizontal.3"
        case .glossary: return "character.book.closed"
        }
    }
}

/// One piece of an article.
public enum HandbookBlock: Hashable, Sendable {
    case heading(LText)
    case paragraph(LText)
    case bullets([LText])
    /// Numbered steps.
    case steps([LText])
    case table(header: [LText], rows: [[LText]])
    /// Something that can damage equipment or hearing, or ruin the show.
    case warning(LText)
    case tip(LText)
    /// Connector face with numbered contacts.
    case connector(ConnectorDiagram)
    /// External page (manufacturer's site for official manuals).
    case link(title: LText, url: String)
}

/// Contacts drawn on a connector face (unit square, origin top-left).
public struct ConnectorDiagram: Hashable, Sendable {
    public enum Shape: Hashable, Sendable { case round, rectangle, jack }
    public struct Pin: Hashable, Sendable {
        public var label: String
        public var x: Double
        public var y: Double
        public init(_ label: String, _ x: Double, _ y: Double) {
            self.label = label
            self.x = x
            self.y = y
        }
    }
    public var shape: Shape
    public var pins: [Pin]
    public var caption: LText
    public init(shape: Shape, pins: [Pin], caption: LText) {
        self.shape = shape
        self.pins = pins
        self.caption = caption
    }
}

public struct HandbookArticle: Identifiable, Hashable, Sendable {
    public var id: String
    public var category: HandbookCategory
    public var title: LText
    public var subtitle: LText
    /// Extra words for search (synonyms, slang, English / Russian names).
    public var tags: [String]
    public var blocks: [HandbookBlock]

    public init(_ id: String, _ category: HandbookCategory, title: LText, subtitle: LText, tags: [String] = [],
                blocks: [HandbookBlock]) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.blocks = blocks
    }

    /// All words of the article in one language, lower-cased, for search.
    func searchText(russian: Bool) -> String {
        var parts = [title.ru, title.en, subtitle.text(russian: russian)] + tags
        for b in blocks {
            switch b {
            case .heading(let t), .paragraph(let t), .warning(let t), .tip(let t): parts.append(t.text(russian: russian))
            case .bullets(let l), .steps(let l): parts += l.map { $0.text(russian: russian) }
            case .table(let h, let rows): parts += h.map { $0.text(russian: russian) } + rows.flatMap { $0.map { $0.text(russian: russian) } }
            case .connector(let d): parts.append(d.caption.text(russian: russian))
            case .link(let t, _): parts.append(t.text(russian: russian))
            }
        }
        return parts.joined(separator: " ").lowercased()
    }
}

public enum Handbook {
    /// Every article except the calculators (those are `AudioCalculator.all`).
    public static let articles: [HandbookArticle] =
        HandbookContent.pinouts + HandbookContent.guides + HandbookContent.consoles + HandbookContent.glossary

    private static let byCategory: [HandbookCategory: [HandbookArticle]] = Dictionary(grouping: articles, by: \.category)

    public static func articles(in category: HandbookCategory) -> [HandbookArticle] { byCategory[category] ?? [] }

    /// Lower-cased search text of every article, built once per language (search runs on every keystroke).
    private static let fullText: [Bool: [String]] = [
        true: articles.map { $0.searchText(russian: true) }, false: articles.map { $0.searchText(russian: false) },
    ]
    private static let titleText: [String] = articles.map { a in
        (a.title.ru + " " + a.title.en + " " + a.tags.joined(separator: " ")).lowercased()
    }

    /// Articles matching every word of the query; title hits first.
    public static func search(_ query: String, russian: Bool, in category: HandbookCategory? = nil) -> [HandbookArticle] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return category.map { articles(in: $0) } ?? articles }
        let text = fullText[russian] ?? []
        var titled: [HandbookArticle] = [], other: [HandbookArticle] = []
        for (i, a) in articles.enumerated() where category == nil || a.category == category {
            guard words.allSatisfy({ text[i].contains($0) }) else { continue }
            if words.allSatisfy({ titleText[i].contains($0) }) { titled.append(a) } else { other.append(a) }
        }
        return titled + other
    }
}
