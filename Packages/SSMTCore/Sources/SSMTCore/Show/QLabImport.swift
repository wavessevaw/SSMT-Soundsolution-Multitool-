import Foundation

/// Import of QLab 4 / 5 workspaces.
///
/// Two sources produce the same `Item` tree:
/// - a running QLab, read over its documented OSC interface (`/cueLists` + `valuesForKeys`) — exact;
/// - the workspace file itself, read best-effort: the format is not published, so only what can
///   be recognised is taken and the report says what was not.
public enum QLabImport {
    /// One QLab cue (or cue list / cart) as read from QLab.
    public struct Item: Equatable, Sendable {
        public var uniqueID = ""
        public var number = ""
        public var name = ""
        public var type = ""
        public var colorName = ""
        public var armed = true
        public var notes = ""
        public var preWait = 0.0
        public var postWait = 0.0
        /// 0 = none, 1 = auto-continue, 2 = auto-follow.
        public var continueMode = 0
        public var duration: Double?
        public var fileTarget: String?
        public var startTime: Double?
        public var endTime: Double?
        public var playCount: Int?
        public var infiniteLoop = false
        public var rate: Double?
        public var cueTargetID: String?
        public var stopTargetWhenDone: Bool?
        public var groupMode: Int?
        /// Main level in dB, when known.
        public var level: Double?
        public var children: [Item] = []

        public init() {}
    }

    public struct Report: Equatable, Sendable {
        public var lists = 0
        public var banks = 0
        public var cues = 0
        public var audio = 0
        /// QLab cue types we do not play yet, with counts (they become Memo cues).
        public var unsupported: [String: Int] = [:]
        /// Cues whose target could not be found.
        public var lostTargets = 0
    }

    // MARK: QLab → show

    /// Builds a show from QLab cue lists (top-level items of type "Cue List" or "Cart").
    public static func makeShow(name: String, lists: [Item]) -> (ShowDocument, Report) {
        var doc = ShowDocument(name: name)
        doc.lists = []
        var report = Report()
        var ids: [String: UUID] = [:]
        var pending: [(UUID, String, Bool)] = [] // (our cue, QLab target id, is "new target")

        func convert(_ q: Item) -> Cue {
            let kind = cueKind(q.type)
            var c = Cue(kind: kind ?? .memo, number: q.number, name: q.name)
            ids[q.uniqueID] = c.id
            report.cues += 1
            c.notes = q.notes
            c.armed = q.armed
            c.color = color(q.colorName)
            c.preWait = max(0, q.preWait)
            c.postWait = max(0, q.postWait)
            c.continueMode = q.continueMode == 1 ? .autoContinue : (q.continueMode == 2 ? .autoFollow : .none)
            if kind == nil {
                report.unsupported[q.type.isEmpty ? "?" : q.type, default: 0] += 1
                c.name = q.name.isEmpty ? "QLab \(q.type)" : q.name
                c.notes = (["[QLab \(q.type)]"] + (q.notes.isEmpty ? [] : [q.notes])).joined(separator: "\n")
            }
            switch kind {
            case .audio?:
                report.audio += 1
                var a = AudioCueParams(file: q.fileTarget ?? "")
                a.start = max(0, q.startTime ?? 0)
                if let e = q.endTime, e > a.start { a.end = e }
                a.plays = q.infiniteLoop ? 0 : max(1, q.playCount ?? 1)
                a.rate = q.rate.map { max(0.05, $0) } ?? 1
                a.level = q.level.map { max(showSilenceDB, $0) } ?? 0
                c.audio = a
                if c.name.isEmpty, let f = q.fileTarget { c.name = ((f as NSString).lastPathComponent as NSString).deletingPathExtension }
            case .fade?:
                var f = FadeCueParams()
                f.duration = max(0, q.duration ?? 5)
                f.stopWhenDone = q.stopTargetWhenDone ?? false
                f.level = q.level ?? (f.stopWhenDone ? showSilenceDB : nil)
                c.fade = f
            case .wait?:
                c.duration = max(0, q.duration ?? 0)
            case .group?:
                switch q.groupMode {
                case 1?: c.groupMode = .enter
                case 3?: c.groupMode = .simultaneous
                case 4?: c.groupMode = .random
                case 6?: c.groupMode = .playlist
                default: c.groupMode = .sequence
                }
                c.children = q.children.map(convert)
            default:
                break
            }
            if let kind, kind.needsTarget, let t = q.cueTargetID, !t.isEmpty { pending.append((c.id, t, false)) }
            return c
        }

        for l in lists {
            let isCart = l.type.lowercased() == "cart"
            if isCart { report.banks += 1 } else { report.lists += 1 }
            let list = CueList(name: l.name.isEmpty ? (isCart ? "Cart" : "Main") : l.name, cues: l.children.map(convert), isBank: isCart)
            doc.lists.append(list)
        }
        if !doc.lists.contains(where: { !$0.isBank }) { doc.lists.insert(CueList(name: "Main"), at: 0) }
        for (cueID, qTarget, _) in pending {
            if let target = ids[qTarget] {
                doc.updateCue(cueID) { $0.target = target }
            } else {
                report.lostTargets += 1
            }
        }
        return (doc, report)
    }

    /// QLab cue type → ours (nil = not supported yet).
    public static func cueKind(_ type: String) -> CueKind? {
        switch type.lowercased().replacingOccurrences(of: " ", with: "") {
        case "audio": return .audio
        case "fade": return .fade
        case "group": return .group
        case "wait": return .wait
        case "memo": return .memo
        case "start": return .start
        case "stop": return .stop
        case "pause": return .pause
        case "load": return .load
        case "reset": return .reset
        case "goto": return .goTo
        case "target": return .target
        case "arm": return .arm
        case "disarm": return .disarm
        case "devamp": return .devamp
        default: return nil
        }
    }

    static func color(_ name: String) -> String {
        let n = name.lowercased()
        return ["red", "orange", "yellow", "green", "blue", "purple"].contains(n) ? n : ""
    }

    // MARK: From QLab's OSC replies

    /// One cue from the `/cueLists` reply (fields `uniqueID`, `number`, `name`, `type`, `colorName`,
    /// `armed`, `cues`). Other properties arrive later through `merge(values:)`.
    public static func item(fromJSON d: [String: Any]) -> Item {
        var q = Item()
        q.uniqueID = d["uniqueID"] as? String ?? ""
        q.number = d["number"] as? String ?? ""
        q.name = (d["name"] as? String) ?? (d["listName"] as? String) ?? ""
        q.type = d["type"] as? String ?? ""
        q.colorName = d["colorName"] as? String ?? ""
        if let a = d["armed"] as? Bool { q.armed = a }
        q.children = (d["cues"] as? [[String: Any]] ?? []).map(item(fromJSON:))
        return q
    }

    /// Keys asked with `valuesForKeys` for every cue.
    public static let valueKeys = ["notes", "preWait", "postWait", "continueMode", "duration", "fileTarget", "startTime",
                                   "endTime", "playCount", "infiniteLoop", "rate", "cueTargetID", "stopTargetWhenDone", "mode"]

    public static func merge(values d: [String: Any], into q: inout Item) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue ?? (d[k] as? String).flatMap(Double.init) }
        if let s = d["notes"] as? String { q.notes = s }
        if let v = num("preWait") { q.preWait = v }
        if let v = num("postWait") { q.postWait = v }
        if let v = num("continueMode") { q.continueMode = Int(v) }
        q.duration = num("duration") ?? q.duration
        if let s = d["fileTarget"] as? String, !s.isEmpty { q.fileTarget = s }
        q.startTime = num("startTime") ?? q.startTime
        q.endTime = num("endTime") ?? q.endTime
        if let v = num("playCount") { q.playCount = Int(v) }
        if let b = d["infiniteLoop"] as? Bool { q.infiniteLoop = b } else if let v = num("infiniteLoop") { q.infiniteLoop = v != 0 }
        q.rate = num("rate") ?? q.rate
        if let s = d["cueTargetID"] as? String, !s.isEmpty { q.cueTargetID = s }
        if let b = d["stopTargetWhenDone"] as? Bool { q.stopTargetWhenDone = b } else if let v = num("stopTargetWhenDone") { q.stopTargetWhenDone = v != 0 }
        if let v = num("mode") { q.groupMode = Int(v) }
    }

    /// Parses a QLab JSON reply (`{"status":"ok","data":…}`) and returns `data`.
    public static func replyData(_ json: String) -> Any? {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (obj["status"] as? String) == "ok" else { return nil }
        return obj["data"]
    }

    // MARK: From the workspace file (best effort)

    /// Reads cue lists from a `.qlab4` / `.qlab5` file. nil = not recognised.
    /// `uid` turns an archiver reference object into its index (platform-specific type).
    public static func lists(fromFile data: Data, uid: @escaping (Any) -> Int? = archiverUID) -> [Item]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            if let j = try? JSONSerialization.jsonObject(with: data) { return lists(fromTree: j) }
            return nil
        }
        if let d = root as? [String: Any], let objects = d["$objects"] as? [Any], let top = d["$top"] as? [String: Any] {
            let resolved = Unarchiver(objects: objects, uid: uid).resolve(top)
            return lists(fromTree: resolved)
        }
        return lists(fromTree: root)
    }

    /// Finds cue lists and cues in a decoded tree by their properties.
    static func lists(fromTree tree: Any) -> [Item]? {
        var found: [Item] = []
        func isCue(_ d: [String: Any]) -> Bool {
            (d["uniqueID"] is String || d["type"] is String) && (d["number"] != nil || d["name"] != nil || d["type"] != nil)
        }
        func childCues(_ d: [String: Any]) -> [[String: Any]] {
            for key in ["cues", "children", "childCues", "cueList"] {
                if let a = d[key] as? [Any] { return a.compactMap { $0 as? [String: Any] }.filter(isCue) }
            }
            return []
        }
        func makeItem(_ d: [String: Any]) -> Item {
            var q = QLabImport.item(fromJSON: d)
            merge(values: d, into: &q)
            if q.fileTarget == nil {
                // File references are often stored under other names: take the first audio-file-like string.
                q.fileTarget = d.values.compactMap { $0 as? String }.first { s in
                    ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac"].contains((s as NSString).pathExtension.lowercased())
                }
            }
            q.children = childCues(d).map(makeItem)
            return q
        }
        func walk(_ x: Any) {
            if let d = x as? [String: Any] {
                let type = (d["type"] as? String ?? "").lowercased()
                if type == "cue list" || type == "cuelist" || type == "cart" {
                    found.append(makeItem(d))
                    return
                }
                d.values.forEach(walk)
            } else if let a = x as? [Any] {
                a.forEach(walk)
            }
        }
        walk(tree)
        if found.isEmpty {
            // No explicit lists: take top-level cues as one list.
            var cues: [Item] = []
            func collect(_ x: Any) {
                if let d = x as? [String: Any] {
                    if isCue(d) { cues.append(makeItem(d)); return }
                    d.values.forEach(collect)
                } else if let a = x as? [Any] { a.forEach(collect) }
            }
            collect(tree)
            guard !cues.isEmpty else { return nil }
            var l = Item()
            l.type = "Cue List"
            l.name = "Main"
            l.children = cues
            found = [l]
        }
        return found
    }

    /// Index stored in an `NSKeyedArchiver` reference (CFKeyedArchiverUID), read from its description.
    public static func archiverUID(_ x: Any) -> Int? {
        if let d = x as? [String: Any] { return d.count == 1 ? d["CF$UID"] as? Int : nil }
        if x is String || x is [Any] || x is Data || x is Date || x is Bool || x is Int || x is Double { return nil }
        let text = String(describing: x)
        guard String(describing: type(of: x)).contains("UID") || text.contains("KeyedArchiverUID") else { return nil }
        // Linux: a Swift class with a `value` field; macOS: "<CFKeyedArchiverUID …>{value = 5}".
        for c in Mirror(reflecting: x).children where c.label == "value" {
            if let v = c.value as? UInt32 { return Int(v) }
            if let v = c.value as? Int { return v }
            if let v = c.value as? UInt64 { return Int(v) }
        }
        guard let r = text.range(of: #"value = (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].split(separator: " ").last ?? "")
    }

    /// Minimal resolver for `NSKeyedArchiver` object graphs into plain dictionaries / arrays / strings.
    struct Unarchiver {
        let objects: [Any]
        let uid: (Any) -> Int?

        func resolve(_ x: Any, depth: Int = 0) -> Any {
            guard depth < 60 else { return "" }
            if let i = uid(x) {
                guard i >= 0, i < objects.count else { return "" }
                return resolve(objects[i], depth: depth + 1)
            }
            if let s = x as? String { return s == "$null" ? "" : s }
            if let a = x as? [Any] { return a.map { resolve($0, depth: depth + 1) } }
            guard let d = x as? [String: Any] else { return x }
            if let keys = d["NS.keys"] as? [Any], let vals = d["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, v) in zip(keys, vals) {
                    if let key = resolve(k, depth: depth + 1) as? String { out[key] = resolve(v, depth: depth + 1) }
                }
                return out
            }
            if let vals = d["NS.objects"] as? [Any] { return vals.map { resolve($0, depth: depth + 1) } }
            if let s = d["NS.string"] as? String { return s }
            if let rel = d["NS.relative"] { return resolve(rel, depth: depth + 1) }
            var out: [String: Any] = [:]
            for (k, v) in d where k != "$class" { out[k] = resolve(v, depth: depth + 1) }
            return out
        }
    }
}
