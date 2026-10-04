import SSMTCore
import SwiftUI

/// The five stages shown in the sidebar; each covers one or more wizard steps.
enum WizardStage: Int, CaseIterable {
    case prepare, capture, align, eq, done

    static func of(_ step: WizardStep) -> WizardStage {
        switch step {
        case .preparation: return .prepare
        case .baseline, .subOnly, .mainsOnly: return .capture
        case .results, .verification: return .align
        case .eqPoints, .eqTuning, .eqVerification: return .eq
        case .finished: return .done
        }
    }

    var icon: String {
        switch self {
        case .prepare: return "checklist"
        case .capture: return "waveform"
        case .align: return "dial.medium"
        case .eq: return "slider.vertical.3"
        case .done: return "doc.text"
        }
    }
}

/// Glass sidebar: brand, the wizard stages (or the expert setup panels) and a few utility items.
struct AppSidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var loc: Localizer
    var brandNamespace: Namespace.ID? = nil
    var showBrand = true
    @State private var showAbout = false
    @State private var brandTaps = 0
    @State private var brandTapTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 14)
            sectionSwitch
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            if model.section == .show {
                showItems
                Spacer(minLength: 16)
            } else if model.section == .inputList {
                inputListItems
                Spacer(minLength: 16)
            } else if model.section == .assist {
                Spacer(minLength: 16)
            } else if model.appMode == .wizard {
                stages
                Spacer(minLength: 16)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 18)
                utilities.padding(.vertical, 10)
            } else {
                SetupSidebar(expert: true)
            }
        }
        .frame(width: 272)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassBackground(radius: 22))
    }

    /// Function #1 / function #2.
    private var sectionSwitch: some View {
        VStack(spacing: 4) {
            sectionRow(.setup, icon: "dial.medium", title: loc.t("section.setup"))
            sectionRow(.inputList, icon: "list.bullet.rectangle", title: loc.t("section.inputList"), subtitle: loc.t("section.inputList.subtitle"))
            sectionRow(.show, icon: "play.rectangle.on.rectangle", title: loc.t("section.show"), subtitle: "Show Control Center")
            sectionRow(.assist, icon: "slider.vertical.3", title: loc.t("section.assist"), subtitle: loc.t("section.assist.subtitle"))
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    private func sectionRow(_ s: AppSection, icon: String, title: String, subtitle: String? = nil) -> some View {
        let on = model.section == s
        return Button { model.section = s } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer()
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Document actions of Qtrl.
    private var showItems: some View {
        VStack(alignment: .leading, spacing: 2) {
            UtilityRow(icon: "doc", title: loc.t("show.new")) { model.show.newDocument() }
            UtilityRow(icon: "folder", title: loc.t("show.open")) { model.show.open() }
            UtilityRow(icon: "square.and.arrow.down", title: loc.t("show.save")) { model.show.save() }
            UtilityRow(icon: "square.and.arrow.down.on.square", title: loc.t("il.saveAs")) { model.show.save(as: true) }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 8)
            UtilityRow(icon: "waveform.badge.plus", title: loc.t("show.addAudio")) { model.show.chooseAudioFiles() }
            UtilityRow(icon: "questionmark.folder", title: loc.t("show.relink")) { model.show.relinkMissing() }
            UtilityRow(icon: "hifispeaker.2", title: loc.t("show.settings")) { model.show.showSettings = true }
            UtilityRow(icon: "antenna.radiowaves.left.and.right", title: loc.t("osc.title")) { model.show.showOSC = true }
        }
        .padding(.horizontal, 10)
    }

    /// Document actions of the input list tab.
    private var inputListItems: some View {
        VStack(alignment: .leading, spacing: 2) {
            UtilityRow(icon: "doc", title: loc.t("il.new")) { model.inputList.newDocument() }
            UtilityRow(icon: "folder", title: loc.t("il.open")) { model.inputList.open() }
            UtilityRow(icon: "square.and.arrow.down", title: loc.t("il.save")) { model.inputList.save() }
            UtilityRow(icon: "square.and.arrow.down.on.square", title: loc.t("il.saveAs")) { model.inputList.save(as: true) }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 8)
            UtilityRow(icon: "doc.richtext", title: loc.t("il.export.pdf")) {
                InputListExporter.export(.pdf, store: model.inputList, loc: loc)
            }
            UtilityRow(icon: "photo", title: loc.t("il.export.pngList")) {
                InputListExporter.export(.pngList, store: model.inputList, loc: loc)
            }
            UtilityRow(icon: "photo.on.rectangle", title: loc.t("il.export.pngStage")) {
                InputListExporter.export(.pngStage, store: model.inputList, loc: loc)
            }
            UtilityRow(icon: "tablecells", title: loc.t("il.export.csvChannels")) {
                InputListExporter.export(.csvChannels, store: model.inputList, loc: loc)
            }
        }
        .padding(.horizontal, 10)
    }

    private var brand: some View {
        Button(action: brandTapped) {
            HStack(spacing: 12) {
                ZStack {
                    if showBrand {
                        BrandMark(variant: .compact, height: 40).modifier(MatchedBrand(namespace: brandNamespace))
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SSMT").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("SoundSolution Multi Tool").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(loc.t("about.title"))
        .popover(isPresented: $showAbout) { AboutView() }
    }

    /// One click on the name opens About; five quick clicks open the hidden game.
    private func brandTapped() {
        brandTaps += 1
        brandTapTask?.cancel()
        if brandTaps >= 5 {
            brandTaps = 0
            GameWindow.show(localizer: loc)
            return
        }
        let taps = brandTaps
        brandTapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            if taps == 1 { showAbout = true }
            brandTaps = 0
        }
    }

    private var stages: some View {
        let current = WizardStage.of(model.wizard.step)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(WizardStage.allCases, id: \.rawValue) { stage in
                StageRow(number: stage.rawValue + 1,
                         title: loc.t("stage.\(stage.rawValue).title"),
                         subtitle: loc.t("stage.\(stage.rawValue).subtitle"),
                         state: stage == current ? .current : (stage.rawValue < current.rawValue ? .done : .upcoming),
                         isLast: stage == .done)
            }
        }
        .padding(.horizontal, 10)
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 2) {
            UtilityRow(icon: "slider.horizontal.3", title: loc.t("settings.title")) { model.showSettings = true }
            UtilityRow(icon: "square.and.arrow.down", title: loc.t("session.save.short")) { model.saveSession() }
            UtilityRow(icon: "doc.richtext", title: loc.t("report.pdf.short")) { model.exportReport(pdf: true, localizer: loc) }
        }
        .padding(.horizontal, 10)
    }
}

/// One stage in the vertical stepper: numbered circle on a connecting line, title and subtitle.
struct StageRow: View {
    enum Phase { case done, current, upcoming }
    var number: Int
    var title: String
    var subtitle: String
    var state: Phase
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    switch state {
                    case .current:
                        Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accentHot], startPoint: .top, endPoint: .bottom))
                        Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    case .done:
                        Circle().fill(Color.white.opacity(0.10))
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.statusGood)
                    case .upcoming:
                        Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                        Text("\(number)").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 32, height: 32)
                if !isLast {
                    Rectangle().fill(Color.white.opacity(state == .done ? 0.25 : 0.12)).frame(width: 1.5, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .upcoming ? Theme.textSecondary : Theme.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .background(alignment: .top) {
            if state == .current {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
                    .frame(height: 46)
            }
        }
    }
}

struct UtilityRow: View {
    var icon: String
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
