import AppKit
import Combine
import SSMTCore
import UniformTypeIdentifiers

/// The open input list / stage plan document: autosaved in Application Support, saved to and
/// opened from `.ssmtinput` files, with undo for every edit.
@MainActor
final class InputListStore: ObservableObject {
    @Published var doc: InputListDocument {
        didSet { if doc != oldValue { scheduleAutosave() } }
    }
    /// File the document was last saved to / opened from.
    @Published private(set) var fileURL: URL?
    @Published var selectedChannels = Set<InputChannel.ID>()
    @Published var selectedMixes = Set<MonitorMix.ID>()
    @Published var selectedItem: StageItem.ID?
    @Published var lastError: String?

    /// The window's undo manager (Edit ▸ Undo / ⌘Z), set by the workspace view.
    weak var undo: UndoManager?
    private var autosaveWork: DispatchWorkItem?

    static let fileType = UTType(filenameExtension: "ssmtinput", conformingTo: .json) ?? .json

    private static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("inputlist-autosave.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.autosaveURL), let d = try? InputListDocument.decode(data) {
            doc = d
        } else {
            doc = Self.starter
        }
    }

    /// A new document starts with a small band so every tool is visible right away (SSMTCore, shared with Windows).
    static var starter: InputListDocument { InputListDocument.starter }

    // MARK: Editing with undo

    /// Applies an edit as one undoable step.
    func edit(_ name: String = "", _ change: (inout InputListDocument) -> Void) {
        let before = doc
        change(&doc)
        if doc != before { trackProgress(before: before) }
        guard doc != before, let undo else { return }
        undo.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(before) }
        }
        undo.setActionName(name)
    }

    /// Patch-size achievements: the largest patch ever built counts.
    private func trackProgress(before: InputListDocument) {
        let c = ProfileCenter.shared
        if doc.channels.count > before.channels.count { c.record("ptch.channelAdded") }
        c.recordMax("ptch.maxChannels", doc.channels.count)
        c.recordMax("ptch.maxDrums", doc.channels.filter { $0.group == .drums }.count)
        c.recordMax("ptch.maxSM58", doc.channels.filter { $0.mic.uppercased().contains("SM58") }.count)
        c.recordMax("ptch.maxPhantom", doc.channels.filter(\.phantom).count)
        c.recordMax("ptch.maxMixes", doc.mixes.count)
        c.recordMax("ptch.maxStageItems", doc.stage.items.count)
        let now = Calendar.current.dateComponents([.weekday, .hour], from: Date())
        if now.weekday == 6, let h = now.hour, h >= 18 { c.record("ptch.fridayEvening") }
    }

    /// Undo / redo step: swaps the document and registers the opposite step.
    private func restore(_ state: InputListDocument) {
        let current = doc
        // Undo can remove rows too: drop selections of rows the restored document does not have.
        selectedChannels.formIntersection(state.channels.map(\.id))
        selectedMixes.formIntersection(state.mixes.map(\.id))
        if let i = selectedItem, !state.stage.items.contains(where: { $0.id == i }) { selectedItem = nil }
        doc = state
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(current) }
        }
    }

    // MARK: Files

    func newDocument() {
        replace(with: InputListDocument(), url: nil)
    }

    /// Swaps the whole document (new / open): selections are cleared and any field being typed in is closed
    /// first, then the document changes a moment later, so no view is left editing a row that is gone.
    private func replace(with d: InputListDocument, url: URL?) {
        clearSelection()
        NSApp.keyWindow?.makeFirstResponder(nil)
        Task { @MainActor [weak self] in
            self?.edit { $0 = d }
            self?.fileURL = url
        }
    }

    private func clearSelection() {
        selectedChannels = []
        selectedMixes = []
        selectedItem = nil
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let d = try InputListDocument.decode(Data(contentsOf: url))
            replace(with: d, url: url)
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    func save(as: Bool = false) {
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.fileType]
            panel.nameFieldStringValue = suggestedName + ".ssmtinput"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        guard let url else { return }
        do {
            try doc.encoded().write(to: url, options: .atomic)
            fileURL = url
        } catch {
            lastError = "\(url.lastPathComponent): \(error)"
        }
    }

    /// File name from the artist / event ("Band - Club").
    var suggestedName: String { doc.suggestedName }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? self.doc.encoded() else { return }
            try? data.write(to: Self.autosaveURL, options: .atomic)
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
