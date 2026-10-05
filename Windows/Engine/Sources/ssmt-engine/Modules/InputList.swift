import Foundation
import SSMTCore

/// Function #2 (Ptch): the open input list / stage plan document, as InputListStore keeps it on the Mac. Every edit
/// goes through SSMTCore (InputListDocument, StagePlan, ChannelTemplate, MicLibrary) and is one undoable step; the
/// document is autosaved a second after each change and saved to and opened from `.ssmtinput` files in exactly the
/// Mac's format (InputListDocument.encoded / decode), so a file moves between the two programs.
///
/// Commands (all start with "il."):
///   il.init                           catalog + state (loads the autosave or the starter document once)
///   il.new / il.open {path} / il.save {path?} / il.csv {kind: channels|mixes, path}
///   il.edit {op, name?, …}            one edit (see `applyEdit`), name = the undo action's name
///   il.undo / il.redo
///   il.mics {id, text}                microphone suggestions for the mic field's menu
///   il.fixture                        the sample document of the Mac snapshot tests (parity check)
/// Events: il.catalog, il.state, il.mics, il.exported, il.progress, il.error.
final class InputListModule: EngineModule {
    /// Print sheets: channel rows per A4 landscape page (InputListPrint.rowsPerPage on the Mac).
    static let rowsPerPage = 24

    private var doc = InputListDocument()
    private var loaded = false
    private var fileURL: URL?
    private var undoStack: [(doc: InputListDocument, name: String)] = []
    private var redoStack: [(doc: InputListDocument, name: String)] = []
    private var autosaveAt: Date?
    private var dataDir: URL?

    private var autosaveURL: URL? {
        dataDir?.appendingPathComponent("inputlist-autosave.json")
    }

    func handle(_ c: Command, engine: Engine) -> Bool {
        guard c.name.hasPrefix("il.") else { return false }
        dataDir = engine.dataDir
        if !loaded { load() }
        switch c.name {
        case "il.init":
            emitCatalog()
            emitState()
        case "il.new":
            replace(with: InputListDocument(), url: nil)
        case "il.open":
            guard let p = c.str("path"), !p.isEmpty else { break }
            let url = URL(fileURLWithPath: p)
            do {
                let d = try InputListDocument.decode(Data(contentsOf: url))
                replace(with: d, url: url)
            } catch {
                emitError("\(url.lastPathComponent): \(error)")
            }
        case "il.save":
            guard let p = c.str("path") ?? fileURL?.path, !p.isEmpty else { break }
            let url = URL(fileURLWithPath: p)
            do {
                try doc.encoded().write(to: url, options: .atomic)
                fileURL = url
                emitState()
            } catch {
                emitError("\(url.lastPathComponent): \(error)")
            }
        case "il.csv":
            guard let p = c.str("path"), !p.isEmpty else { break }
            let url = URL(fileURLWithPath: p)
            let text = c.str("kind") == "mixes" ? doc.mixesCSV : doc.channelsCSV
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Out.emit("il.exported", ["path": p, "empty": doc.channels.isEmpty])
            } catch {
                emitError("\(url.lastPathComponent): \(error)")
            }
        case "il.edit":
            applyEdit(c)
        case "il.undo":
            if let last = undoStack.popLast() {
                redoStack.append((doc: doc, name: last.name))
                doc = last.doc
                scheduleAutosave()
            }
            emitState()
        case "il.redo":
            if let next = redoStack.popLast() {
                undoStack.append((doc: doc, name: next.name))
                doc = next.doc
                scheduleAutosave()
            }
            emitState()
        case "il.mics":
            let s = MicLibrary.suggestions(for: c.str("text") ?? "", limit: 12)
            Out.emit("il.mics", ["id": c.str("id") ?? "", "items": s.isEmpty ? MicLibrary.models : s])
        case "il.fixture":
            doc = Self.sample
            fileURL = nil
            undoStack.removeAll()
            redoStack.removeAll()
            emitCatalog()
            emitState(select: ["channels": [String](), "mixes": [String](), "item": ""])
        default:
            Out.emit("error", ["key": "unknownCommand", "detail": c.name])
        }
        return true
    }

    func tick(_ now: Date, engine: Engine) {
        guard let at = autosaveAt, now >= at else { return }
        autosaveAt = nil
        guard let url = autosaveURL, let data = try? doc.encoded() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: document

    private func load() {
        loaded = true
        if let url = autosaveURL, let data = try? Data(contentsOf: url), let d = try? InputListDocument.decode(data) {
            doc = d
        } else {
            doc = InputListDocument.starter
        }
    }

    /// Applies an edit as one undoable step (InputListStore.edit). True when the document changed.
    @discardableResult
    private func edit(_ name: String = "", _ change: (inout InputListDocument) -> Void) -> Bool {
        let before = doc
        change(&doc)
        guard doc != before else { return false }
        emitProgress(before: before)
        undoStack.append((doc: before, name: name))
        if undoStack.count > 500 { undoStack.removeFirst(undoStack.count - 500) }
        redoStack.removeAll()
        scheduleAutosave()
        return true
    }

    /// New / open: the whole document is swapped as one undoable step and the selection is cleared.
    private func replace(with d: InputListDocument, url: URL?) {
        edit { $0 = d }
        fileURL = url
        emitState(select: ["channels": [String](), "mixes": [String](), "item": ""])
    }

    private func scheduleAutosave() {
        autosaveAt = Date().addingTimeInterval(1)
    }

    // MARK: edits

    private func applyEdit(_ c: Command) {
        let name = c.str("name") ?? ""
        let id = Self.uuid(c.fields["id"])
        let after = Self.uuid(c.fields["after"])
        let ids = Set(Self.uuids(c.fields["ids"]))
        var select: [String: Any]?
        var quiet = false
        switch c.str("op") ?? "" {
        // Channels
        case "addChannel":
            var new: InputChannel.ID?
            edit(name) { new = $0.addChannel(after: after) }
            select = ["channels": new.map { [$0.uuidString] } ?? [String]()]
        case "template":
            guard let t = c.str("template").flatMap({ ChannelTemplate.template(id: $0) }) else { break }
            var new: [InputChannel.ID] = []
            edit(name) { new = $0.insert(t, after: after) }
            select = ["channels": new.map(\.uuidString)]
        case "stereo":
            guard let id else { break }
            edit(name) { _ = $0.makeStereo(id) }
        case "duplicate":
            edit(name) { $0.duplicate(ids) }
        case "move":
            let by = c.int("by") ?? 0
            edit(name) { $0.move(ids, by: by) }
        case "delete":
            edit(name) { $0.delete(ids) }
            select = ["channels": [String]()]
        case "renumber":
            edit(name) { $0.renumber() }
        case "stagebox":
            let prefix = c.str("prefix") ?? ""
            let start = c.int("start") ?? 1
            let onlyEmpty = Self.flag(c.fields["onlyEmpty"]) ?? true
            edit(name) { $0.assignStagebox(prefix: prefix, start: start, onlyEmpty: onlyEmpty) }
        case "pickMic":
            guard let id else { break }
            let model = c.str("model") ?? ""
            edit(name) { d in
                guard let i = d.channels.firstIndex(where: { $0.id == id }) else { return }
                d.channels[i].mic = model
                d.channels[i].phantom = MicLibrary.needsPhantom(model)
            }
        // Monitor mixes
        case "addMix":
            edit(name) { _ = $0.addMix() }
        case "deleteMixes":
            edit(name) { $0.deleteMixes(ids) }
            select = ["mixes": [String]()]
        case "renumberMixes":
            edit(name) { $0.renumberMixes() }
        // Fields
        case "set":
            quiet = Self.flag(c.fields["quiet"]) ?? false
            set(target: c.str("target") ?? "", id: id, key: c.str("key") ?? "", value: c.fields["value"], name: name)
        // Stage plan
        case "stageAdd":
            guard let kind = StageItemKind(rawValue: c.str("kind") ?? "") else { break }
            let label = c.str("label") ?? ""
            var new: StageItem.ID?
            edit(name) { new = $0.stage.add(kind, label: label) }
            select = ["item": new?.uuidString ?? ""]
        case "stageMove":
            guard let id, let x = Self.num(c.fields["x"]), let y = Self.num(c.fields["y"]) else { break }
            edit(name) { $0.stage.move(id, to: (x: x, y: y)) }
        case "stageRemove":
            guard let id else { break }
            edit(name) { $0.stage.remove([id]) }
            select = ["item": ""]
        case "stageRotate":
            guard let id else { break }
            let by = Self.num(c.fields["by"]) ?? 90
            edit(name) { $0.stage.rotate(id, by: by) }
        case "stageDuplicate":
            guard let id else { break }
            var new: StageItem.ID?
            edit(name) { new = $0.stage.duplicate(id) }
            select = ["item": new?.uuidString ?? ""]
        case "stageFront":
            guard let id else { break }
            edit(name) { $0.stage.bringToFront(id) }
        case "stageBack":
            guard let id else { break }
            edit(name) { $0.stage.sendToBack(id) }
        case "stageWidth":
            guard let v = Self.num(c.fields["value"]) else { break }
            edit(name) { $0.stage.width = v; $0.stage.clampAll() }
        case "stageDepth":
            guard let v = Self.num(c.fields["value"]) else { break }
            edit(name) { $0.stage.depth = v; $0.stage.clampAll() }
        case "stageSnap":
            let on = Self.flag(c.fields["value"]) ?? true
            edit(name) { $0.stage.grid = on ? 0.25 : 0 }
        default:
            Out.emit("error", ["key": "unknownCommand", "detail": "il.edit " + (c.str("op") ?? "")])
            return
        }
        emitState(select: select, quiet: quiet)
    }

    /// One field of the document, a channel, a mix or a stage item (the Mac's bindings). Items are found by id on
    /// every write: a row may be gone (deleted, new patch, undo) by the time a field reports its last edit.
    private func set(target: String, id: UUID?, key: String, value v: Any?, name: String) {
        edit(name) { d in
            switch target {
            case "doc":
                switch key {
                case "artist": if let s = v as? String { d.artist = s }
                case "event": if let s = v as? String { d.event = s }
                case "venue": if let s = v as? String { d.venue = s }
                case "engineer": if let s = v as? String { d.engineer = s }
                case "contact": if let s = v as? String { d.contact = s }
                case "notes": if let s = v as? String { d.notes = s }
                case "date":
                    if let s = v as? String, !s.isEmpty {
                        if let date = ISO8601DateFormatter().date(from: s) { d.date = date }
                    } else {
                        d.date = nil
                    }
                default: break
                }
            case "channel":
                guard let id, let i = d.channels.firstIndex(where: { $0.id == id }) else { return }
                switch key {
                case "number": if let n = Self.integer(v) { d.channels[i].number = n }
                case "source": if let s = v as? String { d.channels[i].source = s }
                case "mic": if let s = v as? String { d.channels[i].mic = s }
                case "stand": if let s = v as? String, let t = StandType(rawValue: s) { d.channels[i].stand = t }
                case "phantom": if let b = Self.flag(v) { d.channels[i].phantom = b }
                case "stagebox": if let s = v as? String { d.channels[i].stagebox = s }
                case "insert": if let s = v as? String { d.channels[i].insert = s }
                case "group": if let s = v as? String, let g = ChannelGroup(rawValue: s) { d.channels[i].group = g }
                case "notes": if let s = v as? String { d.channels[i].notes = s }
                default: break
                }
            case "mix":
                guard let id, let i = d.mixes.firstIndex(where: { $0.id == id }) else { return }
                switch key {
                case "number": if let n = Self.integer(v) { d.mixes[i].number = n }
                case "name": if let s = v as? String { d.mixes[i].name = s }
                case "type": if let s = v as? String, let t = MixType(rawValue: s) { d.mixes[i].type = t }
                case "stereo": if let b = Self.flag(v) { d.mixes[i].stereo = b }
                case "notes": if let s = v as? String { d.mixes[i].notes = s }
                default: break
                }
            case "item":
                guard let id, let i = d.stage.items.firstIndex(where: { $0.id == id }) else { return }
                switch key {
                case "label": if let s = v as? String { d.stage.items[i].label = s }
                case "info": if let s = v as? String { d.stage.items[i].info = s }
                case "rotation": if let x = Self.num(v) { d.stage.items[i].rotation = x }
                case "fontSize": if let x = Self.num(v) { d.stage.items[i].fontSize = x }
                case "width": if let x = Self.num(v) { d.stage.items[i].width = x }
                case "depth": if let x = Self.num(v) { d.stage.items[i].depth = x }
                default: break
                }
            default:
                break
            }
        }
    }

    // MARK: events

    private func emitCatalog() {
        Out.emit("il.catalog", [
            "templates": ChannelTemplate.all.map { ["id": $0.id, "count": $0.channels.count] as [String: Any] },
            "micModels": MicLibrary.models,
            "kinds": StageItemKind.allCases.map { ["id": $0.rawValue, "w": $0.defaultSize.w, "d": $0.defaultSize.d] as [String: Any] },
            "stands": StandType.allCases.map(\.rawValue),
            "groups": ChannelGroup.allCases.map(\.rawValue),
            "mixTypes": MixType.allCases.map(\.rawValue),
            "rowsPerPage": Self.rowsPerPage,
        ])
    }

    /// The whole document (the file's own JSON), with what the views derive from it in SSMTCore.
    private func emitState(select: [String: Any]? = nil, quiet: Bool = false) {
        let s = doc.summary
        let summary: [String: Any] = [
            "channelCount": s.channelCount, "phantomCount": s.phantomCount, "mixCount": s.mixCount,
            "stereoMixCount": s.stereoMixCount,
            "models": s.models.map { ["name": $0.name, "count": $0.count] as [String: Any] },
            "stands": s.stands.map { ["type": $0.type.rawValue, "count": $0.count] as [String: Any] },
        ]
        let issues: [[String: Any]] = doc.issues.map { (issue: InputListIssue) -> [String: Any] in
            switch issue {
            case .duplicateNumber(let n): return ["kind": "duplicateNumber", "number": n]
            case .duplicateStagebox(let b): return ["kind": "duplicateStagebox", "stagebox": b]
            case .emptySource(let n): return ["kind": "emptySource", "channel": n]
            }
        }
        var f: [String: Any] = [
            "doc": docJSON(),
            "summary": summary,
            "issues": issues,
            "pages": doc.channelPages(rowsPerPage: Self.rowsPerPage).map { $0.map(\.id.uuidString) },
            "file": fileURL?.lastPathComponent ?? "",
            "path": fileURL?.path ?? "",
            "suggestedName": doc.suggestedName,
            "canUndo": !undoStack.isEmpty,
            "canRedo": !redoStack.isEmpty,
            "undoName": undoStack.last?.name ?? "",
            "redoName": redoStack.last?.name ?? "",
            "quiet": quiet,
        ]
        if let select { f["select"] = select }
        Out.emit("il.state", f)
    }

    private func docJSON() -> Any {
        guard let data = try? doc.encoded(), let o = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return [String: Any]()
        }
        return o
    }

    private func emitError(_ text: String) {
        Out.emit("il.error", ["text": text])
    }

    /// Patch-size achievements (InputListStore.trackProgress): the interface hands these to the profile.
    private func emitProgress(before: InputListDocument) {
        var p: [String: Any] = [
            "channelAdded": doc.channels.count > before.channels.count,
            "maxChannels": doc.channels.count,
            "maxDrums": doc.channels.filter { $0.group == .drums }.count,
            "maxSM58": doc.channels.filter { $0.mic.uppercased().contains("SM58") }.count,
            "maxPhantom": doc.channels.filter(\.phantom).count,
            "maxMixes": doc.mixes.count,
            "maxStageItems": doc.stage.items.count,
        ]
        let now = Calendar.current.dateComponents([.weekday, .hour], from: Date())
        if now.weekday == 6, let h = now.hour, h >= 18 { p["fridayEvening"] = true }
        Out.emit("il.progress", p)
    }

    // MARK: values from the interface

    private static func uuid(_ v: Any?) -> UUID? {
        guard let s = v as? String else { return nil }
        return UUID(uuidString: s)
    }

    private static func uuids(_ v: Any?) -> [UUID] {
        guard let a = v as? [Any] else { return [] }
        return a.compactMap { uuid($0) }
    }

    private static func num(_ v: Any?) -> Double? {
        var value: Double?
        if let n = v as? NSNumber {
            value = n.doubleValue
        } else if let d = v as? Double {
            value = d
        } else if let i = v as? Int {
            value = Double(i)
        }
        guard let x = value, x.isFinite else { return nil }
        return x
    }

    private static func integer(_ v: Any?) -> Int? {
        guard let x = num(v), abs(x) < 1_000_000_000 else { return nil }
        return Int(x.rounded())
    }

    private static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    // MARK: sample

    /// The sample document of the Mac snapshot tests (SnapshotTests.sampleInputList).
    static var sample: InputListDocument {
        var d = InputListDocument()
        d.artist = "The Sample Band"
        d.event = "Club show"
        d.venue = "Main hall"
        d.date = Date(timeIntervalSince1970: 1_800_000_000)
        d.engineer = "FOH: A. Engineer"
        d.contact = "+7 900 000-00-00"
        d.notes = "Drum riser 2.4 × 2 m, 4 power drops on stage."
        for t in ["drums", "bass", "guitar", "keys", "leadVocal", "backingVocals", "playback"] {
            if let template = ChannelTemplate.template(id: t) { d.insert(template) }
        }
        d.assignStagebox(prefix: "SB1-")
        let mixes: [(String, MixType)] = [("Lead vocal", .iem), ("Guitar", .wedge), ("Bass", .wedge), ("Drums", .drumfill), ("Keys", .iem)]
        for (name, type) in mixes {
            d.addMix(type: type)
            d.mixes[d.mixes.count - 1].name = name
            d.mixes[d.mixes.count - 1].stereo = type == .iem
        }
        var p = StagePlan()
        p.width = 10
        p.depth = 6
        p.add(.riser, at: (5, 4.6), label: "Riser")
        p.add(.drumKit, at: (5, 4.6), label: "Drums")
        p.add(.bassAmp, at: (2.2, 4.8), label: "Bass")
        p.add(.guitarAmp, at: (7.8, 4.8), label: "Guitar")
        p.add(.keyboard, at: (8.4, 2.6), label: "Keys")
        p.add(.person, at: (5, 1.6), label: "Lead vocal")
        p.add(.vocalMic, at: (5, 1.0))
        for x in [3.0, 5.0, 7.0] { p.add(.wedge, at: (x, 0.4)) }
        p.add(.diBox, at: (8.4, 3.2))
        p.add(.powerDrop, at: (1.0, 5.6))
        p.add(.text, at: (5, 3.0), label: "4 × power 230 V")
        d.stage = p
        return d
    }
}
