import AppKit
import SSMTCore
import SwiftUI

// MARK: - Calculator

/// Fields on the left, answers recalculated on every keystroke; the values are remembered per calculator.
struct CalculatorView: View {
    @EnvironmentObject var loc: Localizer
    let calculator: AudioCalculator
    let russian: Bool
    @State private var texts: [String: String] = [:]
    @State private var choices: [String: Int] = [:]
    @State private var copied: String?

    private var storageKey: String { "ssmt.handbook.calc." + calculator.id }

    var body: some View {
        let parsed = values()
        let results = calculator.results(parsed.values)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                fields(invalid: parsed.invalid)
                    .frame(minWidth: 300, maxWidth: 380, alignment: .leading)
                answers(results)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "function").foregroundStyle(Theme.textMuted)
                Text(calculator.formula.text(russian: russian))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.18)))
        }
        .onAppear(perform: load)
    }

    // Fields

    private func fields(invalid: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(calculator.fields) { f in
                VStack(alignment: .leading, spacing: 5) {
                    Text(f.label.text(russian: russian)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    fieldControl(f, invalid: invalid.contains(f.id))
                }
            }
            Button(loc.t("hb.reset")) { reset() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private func fieldControl(_ f: AudioCalculator.Field, invalid: Bool) -> some View {
        switch f.kind {
        case .number(let unit, _, _):
            HStack(spacing: 8) {
                TextField("", text: textBinding(f))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(15))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(invalid ? Theme.statusError.opacity(0.8) : Color.white.opacity(0.1)))
                    .help(invalid ? loc.t("hb.invalid") : "")
                // Same width with or without a unit, so the fields line up.
                Text(unit).font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 52, alignment: .leading)
            }
        case .choice(let options):
            Picker("", selection: choiceBinding(f)) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    Text(o.text(russian: russian)).tag(i)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func textBinding(_ f: AudioCalculator.Field) -> Binding<String> {
        Binding(get: { texts[f.id] ?? AudioCalculatorFormat.text(f.initial) },
                set: { texts[f.id] = $0; save(); track(f.id) })
    }

    @State private var lastField: String?
    @State private var sameFieldEdits = 0
    @State private var lastCount = Date.distantPast

    /// Achievements: calculations (one per pause in typing), the same field again and again.
    private func track(_ field: String) {
        let c = ProfileCenter.shared
        sameFieldEdits = field == lastField ? sameFieldEdits + 1 : 1
        lastField = field
        if sameFieldEdits >= 30 { c.record("secret.perfectionist") }
        guard Date().timeIntervalSince(lastCount) > 1.5 else { return }
        lastCount = Date()
        c.record("hb.calc")
        if calculator.id == "delay" { c.record("hb.delayCalc") }
        if calculator.id == "rt60" { c.record("hb.rt60") }
    }

    private func choiceBinding(_ f: AudioCalculator.Field) -> Binding<Int> {
        Binding(get: { choices[f.id] ?? Int(f.initial) }, set: { choices[f.id] = $0; save(); track(f.id) })
    }

    // Answers

    private func answers(_ results: [AudioCalculator.Result]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                if r.primary {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.label.text(russian: russian)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(r.value).font(Theme.numeral(36)).foregroundStyle(Theme.accent)
                                .textSelection(.enabled)
                            Text(r.unit).font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                            copyButton(r)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.08)))
                } else {
                    HStack(spacing: 8) {
                        Text(r.label.text(russian: russian)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 12)
                        Text(r.value + (r.unit.isEmpty ? "" : " " + r.unit)).font(Theme.mono(14)).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        copyButton(r)
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    private func copyButton(_ r: AudioCalculator.Result) -> some View {
        let key = r.label.en
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r.value, forType: .string)
            copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == key { copied = nil } }
        } label: {
            Image(systemName: copied == key ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                .foregroundStyle(copied == key ? Theme.statusGood : Theme.textMuted)
        }
        .buttonStyle(.plain)
        .help(loc.t("hb.copy"))
    }

    // Values

    /// Numbers from the fields (a comma works as the decimal point); a field that is not a number keeps its default.
    private func values() -> (values: [String: Double], invalid: Set<String>) {
        var out: [String: Double] = [:]
        var bad = Set<String>()
        for f in calculator.fields {
            switch f.kind {
            case .number(_, let lo, let hi):
                let t = (texts[f.id] ?? AudioCalculatorFormat.text(f.initial)).replacingOccurrences(of: ",", with: ".")
                    .trimmingCharacters(in: .whitespaces)
                if let v = Double(t), v.isFinite, v >= lo, v <= hi {
                    out[f.id] = v
                } else {
                    out[f.id] = f.initial
                    bad.insert(f.id)
                }
            case .choice:
                out[f.id] = Double(choices[f.id] ?? Int(f.initial))
            }
        }
        return (out, bad)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for f in calculator.fields {
            guard let v = saved[f.id] else { continue }
            switch f.kind {
            case .number: texts[f.id] = v
            case .choice: choices[f.id] = Int(v)
            }
        }
    }

    private func save() {
        var out = texts
        for (k, v) in choices { out[k] = String(v) }
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private func reset() {
        texts = [:]
        choices = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

enum AudioCalculatorFormat {
    /// Default value as typed text (no trailing ".0").
    static func text(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e12 ? String(Int(v)) : String(v)
    }
}

// MARK: - Article

struct ArticleView: View {
    let article: HandbookArticle
    let russian: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, b in
                HandbookBlockView(block: b, russian: russian)
            }
        }
    }
}

struct HandbookBlockView: View {
    let block: HandbookBlock
    let russian: Bool

    var body: some View {
        switch block {
        case .heading(let t):
            Text(t.text(russian: russian)).font(Theme.heading(16)).foregroundStyle(Theme.textPrimary).padding(.top, 4)
        case .paragraph(let t):
            Text(t.text(russian: russian)).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -2)
                        bodyText(t)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(Theme.mono(12, weight: .semibold)).foregroundStyle(.black)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.accent))
                        bodyText(t)
                    }
                }
            }
        case .table(let header, let rows):
            HandbookTable(header: header, rows: rows, russian: russian)
        case .warning(let t):
            callout(t, icon: "exclamationmark.triangle.fill", tint: Theme.statusWarning)
        case .tip(let t):
            callout(t, icon: "lightbulb", tint: Theme.accent)
        case .connector(let d):
            ConnectorFace(diagram: d, russian: russian)
        case .link(let title, let url):
            if let u = URL(string: url) {
                Link(destination: u) {
                    Label(title.text(russian: russian), systemImage: "arrow.up.right.square")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.dataBlue)
            }
        }
    }

    private func bodyText(_ t: LText) -> some View {
        Text(t.text(russian: russian)).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func callout(_ t: LText, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 14))
            Text(t.text(russian: russian)).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}

/// Table with a header row and zebra rows.
struct HandbookTable: View {
    let header: [LText]
    let rows: [[LText]]
    let russian: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                    Text(h.text(russian: russian)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.white.opacity(0.06))
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
                        Text(cell.text(russian: russian))
                            .font(j == 0 ? .system(size: 13, weight: .medium) : .system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(i % 2 == 1 ? Color.white.opacity(0.025) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Connector face: outline and numbered contacts at their places.
struct ConnectorFace: View {
    let diagram: ConnectorDiagram
    let russian: Bool

    private var size: CGSize {
        diagram.shape == .jack ? CGSize(width: 260, height: 70) : CGSize(width: 150, height: 150)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                outline
                ForEach(Array(diagram.pins.enumerated()), id: \.offset) { _, p in
                    pin(p)
                        .position(x: size.width * p.x, y: size.height * p.y)
                }
            }
            .frame(width: size.width, height: size.height)
            Text(diagram.caption.text(russian: russian)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.2)))
    }

    @ViewBuilder private var outline: some View {
        switch diagram.shape {
        case .round:
            Circle().strokeBorder(Theme.textSecondary.opacity(0.7), lineWidth: 2)
                .background(Circle().fill(Color.white.opacity(0.03)))
        case .rectangle:
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.textSecondary.opacity(0.7), lineWidth: 2)
        case .jack:
            // Plug lying on its side: tip on the left, sleeve to the right.
            HStack(spacing: 3) {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 52)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 60)
                Rectangle().fill(Color.white.opacity(0.18)).frame(maxWidth: .infinity)
            }
            .frame(height: 26)
        }
    }

    private func pin(_ p: ConnectorDiagram.Pin) -> some View {
        Text(p.label)
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 5)
            .frame(minWidth: 24, minHeight: 24)
            .background(Capsule().fill(Theme.accent))
    }
}
