import Foundation
import SSMTCore

/// Function #5, the handbook (App/SSMT/Handbook): its content, the page lists and search (HandbookIndex), and the
/// calculators' answers, all from SSMTCore.
///
/// Commands: handbookIndex; handbookList {category, query, lang, favorites}; handbookCalc {id, texts, choices}.
/// Events: handbookIndex {categories, entries}; handbookList {category, query, lang, ids};
/// handbookResults {id, results, invalid}.
final class HandbookModule: EngineModule {
    func handle(_ c: Command, engine: Engine) -> Bool {
        switch c.name {
        case "handbookIndex":
            Out.emit("handbookIndex", [
                "categories": HandbookCategory.allCases.map { cat -> [String: Any] in
                    ["id": cat.rawValue, "title": Self.lt(cat.title), "icon": cat.icon, "count": HandbookIndex.count(cat)]
                },
                "entries": HandbookIndex.all.map(Self.entry),
            ])
        case "handbookList":
            let ru = c.str("lang") != "en"
            let favorites = (c.fields["favorites"] as? [Any])?.compactMap { $0 as? String } ?? []
            let list = HandbookIndex.entries(category: c.str("category") ?? HandbookCategory.calculators.rawValue,
                                             query: c.str("query") ?? "", russian: ru, favorites: favorites)
            Out.emit("handbookList", ["category": c.str("category") ?? "", "query": c.str("query") ?? "",
                                      "lang": ru ? "ru" : "en", "ids": list.map(\.id)])
        case "handbookCalc":
            guard let id = c.str("id"), let entry = HandbookIndex.entry(id), case .calculator(let calc) = entry.kind else {
                return true
            }
            let texts = c.fields["texts"] as? [String: Any] ?? [:]
            let choices = c.fields["choices"] as? [String: Any] ?? [:]
            let parsed = Self.values(calc, texts: texts, choices: choices)
            Out.emit("handbookResults", [
                "id": id,
                "results": calc.results(parsed.values).map { r -> [String: Any] in
                    ["label": Self.lt(r.label), "value": r.value, "unit": r.unit, "primary": r.primary]
                },
                "invalid": parsed.invalid.sorted(),
            ])
        default:
            return false
        }
        return true
    }

    private static func lt(_ t: LText) -> [String: String] { ["ru": t.ru, "en": t.en] }

    /// Default value as typed text (no trailing ".0"), as AudioCalculatorFormat on the Mac.
    static func text(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e12 ? String(Int(v)) : String(v)
    }

    /// Numbers from the fields (a comma works as the decimal point); a field that is not a number or out of range
    /// keeps its default and is reported invalid (CalculatorView.values on the Mac).
    static func values(_ calc: AudioCalculator, texts: [String: Any], choices: [String: Any]) -> (values: [String: Double], invalid: Set<String>) {
        var out: [String: Double] = [:]
        var bad = Set<String>()
        for f in calc.fields {
            switch f.kind {
            case .number(_, let lo, let hi):
                let t = ((texts[f.id] as? String) ?? text(f.initial)).replacingOccurrences(of: ",", with: ".")
                    .trimmingCharacters(in: .whitespaces)
                if let v = Double(t), v.isFinite, v >= lo, v <= hi {
                    out[f.id] = v
                } else {
                    out[f.id] = f.initial
                    bad.insert(f.id)
                }
            case .choice:
                if let n = choices[f.id] as? NSNumber {
                    out[f.id] = Double(n.intValue)
                } else if let n = choices[f.id] as? Int {
                    out[f.id] = Double(n)
                } else if let s = choices[f.id] as? String, let n = Int(s) {
                    out[f.id] = Double(n)
                } else {
                    out[f.id] = Double(Int(f.initial))
                }
            }
        }
        return (out, bad)
    }

    private static func entry(_ e: HandbookEntry) -> [String: Any] {
        var o: [String: Any] = ["id": e.id, "category": e.category.rawValue, "icon": e.icon,
                                "title": ["ru": e.title(true), "en": e.title(false)],
                                "subtitle": ["ru": e.subtitle(true), "en": e.subtitle(false)]]
        switch e.kind {
        case .calculator(let c):
            o["kind"] = "calculator"
            o["formula"] = lt(c.formula)
            o["fields"] = c.fields.map { f -> [String: Any] in
                var d: [String: Any] = ["id": f.id, "label": lt(f.label), "initial": f.initial, "initialText": text(f.initial)]
                switch f.kind {
                case .number(let unit, let lo, let hi):
                    d["kind"] = "number"
                    d["unit"] = unit
                    d["min"] = lo
                    d["max"] = hi
                case .choice(let options):
                    d["kind"] = "choice"
                    d["options"] = options.map(lt)
                }
                return d
            }
        case .article(let a):
            o["kind"] = "article"
            o["blocks"] = a.blocks.map(block)
        }
        return o
    }

    private static func block(_ b: HandbookBlock) -> [String: Any] {
        switch b {
        case .heading(let t): return ["type": "heading", "text": lt(t)]
        case .paragraph(let t): return ["type": "paragraph", "text": lt(t)]
        case .bullets(let l): return ["type": "bullets", "items": l.map(lt)]
        case .steps(let l): return ["type": "steps", "items": l.map(lt)]
        case .table(let header, let rows): return ["type": "table", "header": header.map(lt), "rows": rows.map { $0.map(lt) }]
        case .warning(let t): return ["type": "warning", "text": lt(t)]
        case .tip(let t): return ["type": "tip", "text": lt(t)]
        case .connector(let d):
            let shape: String
            switch d.shape {
            case .round: shape = "round"
            case .rectangle: shape = "rectangle"
            case .jack: shape = "jack"
            }
            return ["type": "connector", "shape": shape, "caption": lt(d.caption),
                    "pins": d.pins.map { ["label": $0.label, "x": $0.x, "y": $0.y] as [String: Any] }]
        case .link(let title, let url): return ["type": "link", "title": lt(title), "url": url]
        }
    }
}
