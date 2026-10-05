import SSMTCore
import SwiftUI

/// FOH Assist, "Learning": the console is read once a second during a real event and written to a recording; after
/// about twenty events the patterns (per kind of source) are what a soundcheck engine is built on. A small local
/// language model (Ollama) answers questions about them. Nothing is sent to the console but queries.
struct LearnScreen: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                Panel(title: loc.t("assist.learn.record"), tint: store.learning ? Theme.statusError : Theme.accent) { RecordPanel() }
                Panel(title: loc.t("assist.learn.live"), tint: Theme.dataBlue) { LiveConsole() }
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 12) {
                    Panel(title: loc.t("assist.learn.progress"), tint: Theme.dataSecondary) { ProgressPanel() }
                    Panel(title: loc.t("assist.learn.patterns"), tint: Theme.signalYellow) { PatternsPanel() }
                    Panel(title: loc.t("assist.llm.title"), tint: Theme.accent) { ModelPanel() }
                    if store.family != .simulator {
                        Panel(title: loc.t("assist.diag"), tint: Theme.dataBlue) { LinkDiagnostics() }
                    }
                }
            }
            .frame(width: 440)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { if store.autoScan { store.refreshRecordings() } }
    }
}

private struct RecordPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(loc.t(store.family == .simulator ? "assist.learn.simNote" : "assist.learn.readOnly"),
                  systemImage: "lock.shield")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dataBlue)
            Text(loc.t("assist.learn.hint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.learning {
                HStack(spacing: 10) {
                    Circle().fill(Theme.statusError).frame(width: 12, height: 12)
                    Text(loc.t("assist.learn.recording") + ": " + store.learnTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(clock(store.learnSeconds)).font(Theme.mono(26, weight: .semibold)).foregroundStyle(Theme.statusError)
                }
                HStack(spacing: 10) {
                    stat("\(store.learnFrames)", loc.t("assist.learn.frames"))
                    stat("\(store.learnChanges)", loc.t("assist.learn.changes"))
                }
                Button { store.stopLearning() } label: {
                    Label(loc.t("assist.learn.stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(SSMTButtonStyle(kind: .danger))
            } else {
                TextField(loc.t("assist.learn.titlePlaceholder"), text: $store.learnTitle).textFieldStyle(.roundedBorder)
                Button { store.startLearning() } label: {
                    Label(loc.t("assist.learn.start"), systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(SSMTButtonStyle(kind: .primary))
                .disabled(!store.isConnected)
            }
        }
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(Theme.mono(20, weight: .semibold))
            Text(t).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private struct ProgressPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let events = store.recordings.filter(\.event).count
        let target = LearnedPatterns.targetEvents
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(format: loc.t("assist.learn.events"), events, target)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.openLearnFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(SSMTButtonStyle()).help(loc.t("assist.learn.openFolder"))
            }
            ProgressView(value: Double(min(events, target)), total: Double(target)).tint(Theme.accent)
            Text(loc.t("assist.learn.progressHint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.recordings.isEmpty {
                Text(loc.t("assist.learn.empty")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            ForEach(store.recordings.prefix(12)) { r in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(r.started.formatted(.dateTime.locale(loc.locale)) + " · " + clock(r.duration)
                             + (r.event ? "" : " · " + loc.t("assist.learn.trial")))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Button { store.deleteRecording(r.file) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textMuted).disabled(store.learning)
                        .help(loc.t("assist.learn.delete"))
                }
            }
        }
    }
}

private struct PatternsPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if let p = store.patterns, !store.recordings.isEmpty {
            Text(p.summary(russian: loc.language == .ru || (loc.language == .system && Locale.current.language.languageCode?.identifier == "ru")))
                .font(Theme.mono(11)).foregroundStyle(Theme.dataSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(loc.t("assist.learn.noPatterns")).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }
}

private struct ModelPanel: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var russian: Bool { loc.language == .ru || (loc.language == .system && Locale.current.language.languageCode?.identifier == "ru") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("assist.llm.hint")).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("http://localhost:11434", text: $store.llmURL).textFieldStyle(.roundedBorder)
                TextField("qwen2.5:1.5b", text: $store.llmModel).textFieldStyle(.roundedBorder).frame(width: 130)
                Button(loc.t("assist.llm.check")) { store.checkModel(loc) }.buttonStyle(SSMTButtonStyle())
            }
            if !store.llmStatus.isEmpty {
                Text(store.llmStatus).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField(loc.t("assist.llm.questionPlaceholder"), text: $store.llmQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
                .onSubmit { store.ask(loc, russian: russian) }
            Button { store.ask(loc, russian: russian) } label: {
                Label(loc.t(store.llmAsking ? "assist.llm.asking" : "assist.llm.ask"), systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(SSMTButtonStyle(kind: .primary))
            .disabled(store.llmAsking || store.llmQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            if !store.llmAnswer.isEmpty {
                Text(store.llmAnswer).font(.system(size: 12)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            }
        }
    }
}

/// What the console holds right now (names, gain, fader, levels), so the engineer sees the data arriving.
private struct LiveConsole: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.strips) { s in
                    HStack(spacing: 10) {
                        Text("\(s.id)").font(Theme.mono(11)).foregroundStyle(Theme.textMuted).frame(width: 22, alignment: .trailing)
                        Text(s.name.isEmpty ? "—" : s.name).font(.system(size: 12, weight: .medium)).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(String(format: "%.1f dB", s.gainDB)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .trailing)
                        Text(s.muted ? "MUTE" : s.faderDB <= -90 ? "−∞" : String(format: "%+.1f", s.faderDB))
                            .font(Theme.mono(11)).foregroundStyle(s.muted ? Theme.statusError : Theme.textPrimary).frame(width: 52, alignment: .trailing)
                        LiveMeter(meters: store.liveMeters, id: s.id).frame(height: 6)
                    }
                    .padding(.vertical, 5)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }
}

private struct LiveMeter: View {
    @ObservedObject var meters: AssistMeters
    let id: Int

    var body: some View {
        let db = meters.channels[id] ?? -120
        let x = CGFloat(max(0, min(1, (db + 60) / 60)))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(db > -3 ? Theme.statusError : Theme.accent).frame(width: g.size.width * x)
            }
        }
    }
}

/// A function that is off on a real console in this version: says so, and points to learning (and the simulator).
struct ComingSoonScreen: View {
    @EnvironmentObject var store: AssistStore
    @EnvironmentObject var loc: Localizer
    let mode: AssistStore.Mode

    var body: some View {
        VStack(spacing: 14) {
            Text(loc.t("assist.soon.badge")).font(.system(size: 11, weight: .bold)).tracking(1.5)
                .foregroundStyle(Theme.signalYellow)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Theme.signalYellow.opacity(0.14)))
            Text(loc.t("assist.soon.title.\(mode.rawValue)")).font(.system(size: 20, weight: .bold)).multilineTextAlignment(.center)
            Text(loc.t("assist.soon.text.\(mode.rawValue)")).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(loc.t("assist.soon.toLearn")) { store.mode = .learn }.buttonStyle(SSMTButtonStyle(kind: .primary))
                Button(loc.t("assist.soon.toSim")) {
                    store.disconnect()
                    store.family = .simulator
                    store.connect()
                    store.mode = mode
                }
                .buttonStyle(SSMTButtonStyle())
            }
        }
        .padding(34)
        .frame(maxWidth: 620)
        .glassCard()
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}

private func clock(_ s: Double) -> String {
    let t = max(0, Int(s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}
