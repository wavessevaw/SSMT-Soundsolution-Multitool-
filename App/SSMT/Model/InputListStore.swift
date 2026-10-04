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

    /// A new document starts with a small band so every tool is visible right away.
    static var starter: InputListDocument {
        var d = InputListDocument()
        d.stage.add(.riser, at: (5, 4.5), label: "Drum riser")
        d.stage.add(.drumKit, at: (5, 4.5), label: "Drums")
        d.stage.add(.person, at: (5, 1.2), label: "Lead vocal")
        d.stage.add(.wedge, at: (5, 0.4), label: "Mix 1")
        d.stage.add(.text, at: (5, 0.0), label: "Audience")
        return d
    }

    // MARK: Editing with undo

    /// Applies an edit as one undoable step.
    func edit(_ name: String = "", _ change: (inout InputListDocument) -> Void) {
        let before = doc
        change(&doc)
        guard doc != before, let undo else { return }
        undo.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(before) }
        }
        undo.setActionName(name)
    }

    /// Undo / redo step: swaps the document and registers the opposite step.
    private func restore(_ state: InputListDocument) {
        let current = doc
        doc = state
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restore(current) }
        }
    }

    // MARK: Files

    func newDocument() {
        edit { $0 = InputListDocument() }
        fileURL = nil
        selectedChannels = []
        selectedItem = nil
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let d = try InputListDocument.decode(Data(contentsOf: url))
            edit { $0 = d }
            fileURL = url
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
    var suggestedName: String {
        let parts = [doc.artist, doc.event].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = parts.isEmpty ? "Ptch" : parts.joined(separator: " - ")
        return name.replacingOccurrences(of: "/", with: "-")
    }

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
