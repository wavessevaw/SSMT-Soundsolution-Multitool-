import AppKit
import SSMTCore
import SwiftUI

/// Printable sheets (A4 landscape, black on white) and the export of the input list tab.
enum InputListPrint {
    static let page = CGSize(width: 842, height: 595)
    static let rowsPerPage = 24
}

/// Show header printed on every sheet.
struct PrintHeader: View {
    @EnvironmentObject var loc: Localizer
    var doc: InputListDocument
    var title: String
    var page: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(doc.artist.isEmpty ? title : doc.artist).font(.system(size: 20, weight: .bold))
                Spacer()
                Text(page.isEmpty ? title : "\(title) · \(page)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(white: 0.35))
            }
            let line = [doc.event, doc.venue, doc.date.map { $0.formatted(.dateTime.day().month(.wide).year().locale(loc.locale)) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let contact = [doc.engineer, doc.contact].filter { !$0.isEmpty }.joined(separator: " · ")
            HStack {
                Text(line).font(.system(size: 11))
                Spacer()
                Text(contact).font(.system(size: 11))
            }
            .foregroundStyle(Color(white: 0.25))
            Rectangle().fill(Color.black).frame(height: 1.5).padding(.top, 4)
        }
    }
}

/// One sheet of the channel list.
struct ChannelSheet: View {
    @EnvironmentObject var loc: Localizer
    var doc: InputListDocument
    var rows: [InputChannel]
    var page: String

    private let cols: [(String, CGFloat)] = [("№", 34), ("source", 150), ("mic", 120), ("stand", 92), ("48V", 34),
                                             ("stagebox", 66), ("insert", 76), ("group", 76), ("notes", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrintHeader(doc: doc, title: loc.t("il.print.title"), page: page)
            VStack(spacing: 0) {
                row(header: true, cells: cols.map { $0.0 == "№" || $0.0 == "48V" ? $0.0 : loc.t("il.col.\($0.0)") }, color: nil)
                ForEach(Array(rows.enumerated()), id: \.element.id) { k, c in
                    row(header: false,
                        cells: ["\(c.number)", c.source, c.mic, c.stand == .none ? "" : loc.t("stand.\(c.stand.rawValue)"),
                                c.phantom ? "48V" : "", c.stagebox, c.insert, loc.t("chgroup.\(c.group.rawValue)"), c.notes],
                        color: c.group.color, shade: k % 2 == 1)
                }
            }
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: InputListPrint.page.width, height: InputListPrint.page.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func row(header: Bool, cells: [String], color: Color?, shade: Bool = false) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(color ?? .clear).frame(width: 4)
            ForEach(Array(cells.enumerated()), id: \.offset) { i, text in
                let w = cols[i].1
                Text(text)
                    .font(.system(size: header ? 9 : 10.5, weight: header || i <= 1 ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 5)
                    .frame(width: w > 0 ? w : nil, alignment: i == 0 ? .trailing : .leading)
                    .frame(maxWidth: w > 0 ? nil : .infinity, alignment: .leading)
                if i < cells.count - 1 { Rectangle().fill(Color(white: 0.75)).frame(width: 0.5) }
            }
        }
        .frame(height: header ? 18 : 19)
        .background(header ? Color(white: 0.85) : (shade ? Color(white: 0.95) : Color.white))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.75)).frame(height: 0.5) }
    }
}

/// Monitor mixes, pull list and notes.
struct MixesSheet: View {
    @EnvironmentObject var loc: Localizer
    var doc: InputListDocument
    var page: String

    var body: some View {
        let s = doc.summary
        VStack(alignment: .leading, spacing: 14) {
            PrintHeader(doc: doc, title: loc.t("il.print.title"), page: page)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("il.mixes")).font(.system(size: 13, weight: .bold))
                    if doc.mixes.isEmpty {
                        Text("—").font(.system(size: 11))
                    }
                    ForEach(doc.mixes.sorted { $0.number < $1.number }) { m in
                        HStack(spacing: 8) {
                            Text("\(m.number)").font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 22, alignment: .trailing)
                            Text(m.name).font(.system(size: 11)).frame(width: 150, alignment: .leading)
                            Text(loc.t("mixtype.\(m.type.rawValue)") + (m.stereo ? " · stereo" : "")).font(.system(size: 11)).frame(width: 110, alignment: .leading)
                            Text(m.notes).font(.system(size: 10)).foregroundStyle(Color(white: 0.3))
                        }
                        Rectangle().fill(Color(white: 0.8)).frame(height: 0.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("il.summary")).font(.system(size: 13, weight: .bold))
                    Text(String(format: loc.t("il.print.counts"), s.channelCount, s.phantomCount, s.mixCount)).font(.system(size: 11))
                    ForEach(Array(s.models.enumerated()), id: \.offset) { _, m in
                        Text("\(m.count) × \(m.name)").font(.system(size: 11))
                    }
                    if !s.stands.isEmpty {
                        Text(loc.t("il.sum.stands")).font(.system(size: 11, weight: .semibold)).padding(.top, 6)
                        ForEach(Array(s.stands.enumerated()), id: \.offset) { _, st in
                            Text("\(st.count) × " + loc.t("stand.\(st.type.rawValue)")).font(.system(size: 11))
                        }
                    }
                }
                .frame(width: 250, alignment: .leading)
            }
            if !doc.notes.isEmpty {
                Text(loc.t("il.notes")).font(.system(size: 13, weight: .bold))
                Text(doc.notes).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: InputListPrint.page.width, height: InputListPrint.page.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

/// The stage plan sheet.
struct StageSheet: View {
    @EnvironmentObject var loc: Localizer
    var doc: InputListDocument
    var page: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrintHeader(doc: doc, title: loc.t("il.stage"), page: page)
            StagePlanDrawing(plan: doc.stage, ink: .print, audience: loc.t("stage.audience"), showGrid: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(28)
        .frame(width: InputListPrint.page.width, height: InputListPrint.page.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

@MainActor
enum InputListExporter {
    /// All sheets of the document in print order.
    static func sheets(_ doc: InputListDocument, loc: Localizer) -> [AnyView] {
        let pages = doc.channelPages(rowsPerPage: InputListPrint.rowsPerPage)
        let total = pages.count + 2
        var out: [AnyView] = pages.enumerated().map { i, rows in
            AnyView(ChannelSheet(doc: doc, rows: rows, page: "\(i + 1) / \(total)").environmentObject(loc))
        }
        out.append(AnyView(MixesSheet(doc: doc, page: "\(pages.count + 1) / \(total)").environmentObject(loc)))
        out.append(AnyView(StageSheet(doc: doc, page: "\(total) / \(total)").environmentObject(loc)))
        return out
    }

    enum Kind { case pdf, pngList, pngStage, csvChannels, csvMixes }

    static func export(_ kind: Kind, store: InputListStore, loc: Localizer) {
        let doc = store.doc
        let ext: String
        switch kind {
        case .pdf: ext = "pdf"
        case .pngList, .pngStage: ext = "png"
        case .csvChannels, .csvMixes: ext = "csv"
        }
        let suffix: String
        switch kind {
        case .pngStage: suffix = " - stage"
        case .csvMixes: suffix = " - mixes"
        default: suffix = ""
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = store.suggestedName + suffix + "." + ext
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .pdf:
                try writePDF(sheets(doc, loc: loc), to: url)
            case .pngList:
                let s = sheets(doc, loc: loc)
                try writePNG(AnyView(VStack(spacing: 0) { ForEach(0..<(s.count - 1), id: \.self) { s[$0] } }), to: url)
            case .pngStage:
                try writePNG(AnyView(StageSheet(doc: doc, page: "").environmentObject(loc)), to: url)
            case .csvChannels:
                try doc.channelsCSV.write(to: url, atomically: true, encoding: .utf8)
            case .csvMixes:
                try doc.mixesCSV.write(to: url, atomically: true, encoding: .utf8)
            }
            ProfileCenter.shared.record("ptch.export")
            if doc.channels.isEmpty { ProfileCenter.shared.record("ptch.emptyExport") }
        } catch {
            store.lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    /// Vector PDF, one page per sheet.
    static func writePDF(_ pages: [AnyView], to url: URL) throws {
        var box = CGRect(origin: .zero, size: InputListPrint.page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for page in pages {
            let renderer = ImageRenderer(content: page.environment(\.colorScheme, .light))
            renderer.render { _, render in
                ctx.beginPDFPage(nil)
                render(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }

    /// PNG at 2× for messengers and e-mail.
    static func writePNG(_ view: AnyView, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}

/// Export menu of the tab.
struct InputListExportMenu: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Menu {
            Button(loc.t("il.export.pdf")) { InputListExporter.export(.pdf, store: store, loc: loc) }
            Divider()
            Button(loc.t("il.export.pngList")) { InputListExporter.export(.pngList, store: store, loc: loc) }
            Button(loc.t("il.export.pngStage")) { InputListExporter.export(.pngStage, store: store, loc: loc) }
            Divider()
            Button(loc.t("il.export.csvChannels")) { InputListExporter.export(.csvChannels, store: store, loc: loc) }
            Button(loc.t("il.export.csvMixes")) { InputListExporter.export(.csvMixes, store: store, loc: loc) }
        } label: {
            Label(loc.t("il.export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Theme.accent.opacity(0.18)))
    }
}
