import AppKit
import SSMTCore
import SwiftUI

/// Printable/exportable report (PNG/PDF) in the SSMT style.
struct ReportView: View {
    @EnvironmentObject var loc: Localizer
    var report: SetupReport
    var wizard: SetupWizard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let a = report.alignment { alignmentSection(a) }
            if let v = report.verification { verificationSection(v) }
            if let e = report.eq { eqSection(e) }
            conditions
        }
        .padding(28)
        .frame(width: 1100, alignment: .topLeading)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            BrandMark(variant: .full, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("report.title")).font(Theme.heading(26)).foregroundStyle(Theme.textPrimary)
                Text(report.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(loc.locale))).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("SSMT").font(Theme.label(13)).foregroundStyle(Theme.textMuted)
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func alignmentSection(_ a: SetupReport.Alignment) -> some View {
        Panel(title: loc.t("report.alignment"), marking: String(format: loc.t("report.crossover"), a.crossover)) {
            HStack(spacing: 12) {
                cell(loc.t(a.delayTarget == .mains ? "card.delay.mains" : "card.delay.sub"),
                     a.delayTarget == .none ? "0.00 ms" : String(format: "+%.2f ms", a.delayMs),
                     String(format: "≈ %.2f m", a.delayMeters))
                cell(loc.t("card.polarity"), loc.t(a.invertPolarity ? "polarity.invert" : "polarity.normal"), "")
                cell(loc.t("card.level"), String(format: "%+.1f dB", a.subLevelDB), "")
            }
            if a.ambiguous { HazardNotice(text: loc.t("results.ambiguous")) }
        }
    }

    private func verificationSection(_ v: SetupReport.Verification) -> some View {
        Panel(title: loc.t("report.verification"), marking: loc.t("verdict.\(v.verdict.rawValue)")) {
            HStack(spacing: 12) {
                cell(loc.t("verify.dip"), fmt(v.dipAfterDB, "%.1f dB"), loc.t("curve.before") + ": " + fmt(v.dipBeforeDB, "%.1f dB"))
                cell(loc.t("verify.sum"), fmt(v.summationAfterDB, "%+.1f dB"), loc.t("curve.before") + ": " + fmt(v.summationBeforeDB, "%+.1f dB"))
                cell(loc.t("verify.predictionError"), String(format: "%.1f dB", v.predictionErrorDB), "")
            }
            ComparisonPlotView(curves: alignmentCurves, band: wizard.alignment?.overlapBand).frame(height: 230)
        }
    }

    private func eqSection(_ e: SetupReport.EQ) -> some View {
        Panel(title: loc.t("report.eq"), marking: String(format: loc.t("report.eqMarking"), e.points, e.iterations)) {
            HStack(spacing: 12) {
                cell(loc.t("gauge.deviation"), e.deviationAfterDB.map { String(format: "±%.1f dB", $0) } ?? "—",
                     loc.t("curve.before") + String(format: ": ±%.1f dB", e.deviationBeforeDB))
                cell(loc.t("gauge.score"), e.scoreAfter.map { "\($0)" } ?? "\(e.scoreBefore)",
                     loc.t("curve.before") + ": \(e.scoreBefore)")
                cell(loc.t("eq.target"), loc.t("target.\(e.targetName)"), "")
            }
            if let r = wizard.eqResult {
                ComparisonPlotView(curves: eqCurves(r), band: r.workingRange, range: 20...20000).frame(height: 230)
            }
            filterTable(e.filters)
            Text(loc.t("gauge.score.note")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    private var conditions: some View {
        Panel(title: loc.t("report.conditions")) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                row(loc.t("setup.interface"), "\(report.interfaceName == "Simulation" ? loc.t("setup.simulation") : report.interfaceName) · \(Int(report.sampleRate)) Hz")
                row(loc.t("setup.temperature"), String(format: "%.0f °C", report.temperatureCelsius))
                row(loc.t("cal.mic"), report.microphoneCalibrationName ?? loc.t("cal.mic.uncalibrated"))
                if let d = report.referenceDelayMs { row(loc.t("report.delayLocked"), String(format: "%.2f ms", d)) }
            }
        }
    }

    // MARK: Pieces

    private var alignmentCurves: [ComparisonPlotView.Curve] {
        var c: [ComparisonPlotView.Curve] = []
        if let b = wizard.baseline?.transfer { c.append(.init(label: loc.t("curve.before"), transfer: b, color: Theme.textMuted)) }
        if let p = wizard.prediction { c.append(.init(label: loc.t("curve.prediction"), transfer: p, color: Theme.dataBlue, dashed: true)) }
        if let v = wizard.verification?.transfer { c.append(.init(label: loc.t("curve.after"), transfer: v, color: Theme.accent)) }
        return c
    }

    private func eqCurves(_ r: EQResult) -> [ComparisonPlotView.Curve] {
        var c: [ComparisonPlotView.Curve] = [
            .init(label: loc.t("curve.before"), transfer: .fromDB(r.measuredDB, frequencies: r.frequencies), color: Theme.textMuted),
            .init(label: loc.t("eq.target"), transfer: .fromDB(r.targetDB, frequencies: r.frequencies), color: Theme.dataBlue, dashed: true),
        ]
        if let after = wizard.eqAfterAverage {
            c.append(.init(label: loc.t("curve.after"), transfer: after.asTransferFunction, color: Theme.accent))
        } else {
            c.append(.init(label: loc.t("curve.prediction"), transfer: .fromDB(r.predictedDB, frequencies: r.frequencies), color: Theme.accent))
        }
        return c
    }

    private func filterTable(_ filters: [PEQFilter]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
            GridRow {
                ForEach(["#", loc.t("report.group"), "Fc", "Gain", "Q"], id: \.self) {
                    Text($0).font(Theme.label(11)).foregroundStyle(Theme.textMuted)
                }
            }
            ForEach(Array(filters.enumerated()), id: \.offset) { i, f in
                GridRow {
                    Text("\(i + 1)").font(Theme.mono(12))
                    Text(loc.t(f.group == .sub ? "group.subs" : "group.mains")).font(Theme.label(12))
                    Text(f.frequencyLabel).font(Theme.mono(12))
                    Text(String(format: "%+.1f dB", f.gainDB)).font(Theme.mono(12, weight: .semibold))
                    Text(f.widthLabel(inOctaves: wizard.configuration.processor.bandwidthInOctaves)).font(Theme.mono(12))
                }
            }
        }
    }

    private func cell(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.label(11)).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.numeral(26)).foregroundStyle(Theme.textPrimary)
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.panelRaised))
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(Theme.label(12)).foregroundStyle(Theme.textSecondary)
            Text(v).font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
        }
    }

    private func fmt(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "—" }
}

@MainActor
enum ReportExporter {
    /// Renders the report and asks where to save it (PNG at 2× or vector PDF).
    static func export(_ view: some View, pdf: Bool) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SSMT-report." + (pdf ? "pdf" : "png")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let renderer = ImageRenderer(content: view)
        if pdf {
            var ok = true
            renderer.render { size, render in
                var box = CGRect(origin: .zero, size: size)
                guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { ok = false; return }
                ctx.beginPDFPage(nil)
                render(ctx)
                ctx.endPDFPage()
                ctx.closePDF()
            }
            if !ok { throw CocoaError(.fileWriteUnknown) }
        } else {
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: url)
        }
    }
}
