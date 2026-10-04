import Foundation

// MARK: - OSC 1.0 messages

public enum OSCArgument: Codable, Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)
    /// Binary blob (console meters arrive this way).
    case blob(Data)

    var tag: Character {
        switch self {
        case .int: return "i"
        case .float: return "f"
        case .string: return "s"
        case let .bool(b): return b ? "T" : "F"
        case .blob: return "b"
        }
    }

    /// Text shown in lists and the monitor ("1", "0.5", "\"Go+\"", "true").
    public var display: String {
        switch self {
        case let .int(v): return "\(v)"
        case let .float(v): return String(format: "%g", v)
        case let .string(s): return "\"\(s)\""
        case let .bool(b): return b ? "true" : "false"
        case let .blob(d): return "<\(d.count) bytes>"
        }
    }
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public var display: String { ([address] + arguments.map(\.display)).joined(separator: " ") }

    /// Binary OSC packet (big-endian, 4-byte aligned).
    public func encoded() -> Data {
        var d = Data()
        Self.appendString(address, to: &d)
        Self.appendString("," + String(arguments.map(\.tag)), to: &d)
        for a in arguments {
            switch a {
            case let .int(v): withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) }
            case let .float(v): withUnsafeBytes(of: v.bitPattern.bigEndian) { d.append(contentsOf: $0) }
            case let .string(s): Self.appendString(s, to: &d)
            case .bool: break
            case let .blob(b):
                withUnsafeBytes(of: UInt32(b.count).bigEndian) { d.append(contentsOf: $0) }
                d.append(b)
                while d.count % 4 != 0 { d.append(0) }
            }
        }
        return d
    }

    private static func appendString(_ s: String, to d: inout Data) {
        d.append(contentsOf: Array(s.utf8))
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
    }

    /// Parses a packet; bundles return their messages flattened. nil for malformed data.
    public static func decode(_ data: Data) -> [OSCMessage]? {
        let bytes = [UInt8](data)
        var i = 0
        func readString() -> String? {
            guard let end = bytes[i...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: bytes[i..<end], as: UTF8.self)
            i = (end + 4) & ~3
            return i <= bytes.count ? s : nil
        }
        func read32() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            let v = bytes[i..<i + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            i += 4
            return v
        }
        guard !bytes.isEmpty else { return nil }
        if bytes.starts(with: Array("#bundle".utf8) + [0]) {
            i = 16 // "#bundle\0" + 8-byte time tag
            var out: [OSCMessage] = []
            while i + 4 <= bytes.count {
                guard let size = read32(), i + Int(size) <= bytes.count,
                      let inner = decode(Data(bytes[i..<i + Int(size)])) else { return nil }
                out += inner
                i += Int(size)
            }
            return out
        }
        guard let address = readString(), address.hasPrefix("/") else { return nil }
        guard i < bytes.count else { return [OSCMessage(address)] }
        guard let tags = readString(), tags.hasPrefix(",") else { return nil }
        var args: [OSCArgument] = []
        for t in tags.dropFirst() {
            switch t {
            case "i": guard let v = read32() else { return nil }; args.append(.int(Int32(bitPattern: v)))
            case "f": guard let v = read32() else { return nil }; args.append(.float(Float(bitPattern: v)))
            case "s": guard let s = readString() else { return nil }; args.append(.string(s))
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "b":
                guard let n = read32(), i + Int(n) <= bytes.count else { return nil }
                args.append(.blob(Data(bytes[i..<i + Int(n)])))
                i = (i + Int(n) + 3) & ~3
            default: return nil // unsupported type: refuse rather than misread
            }
        }
        return [OSCMessage(address, args)]
    }
}

// MARK: - Devices and presets

/// What is on the other end; decides default port, instructions and command templates.
public enum OSCDeviceKind: String, Codable, CaseIterable, Sendable {
    case resolume, eos, grandMA3, magicQ, x32, generic

    /// A kind this version no longer lists (from an older show) opens as a generic OSC device, address and port kept.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OSCDeviceKind(rawValue: raw) ?? .generic
    }

    public var defaultPort: UInt16 {
        switch self {
        case .resolume: return 7000
        case .eos, .grandMA3, .magicQ: return 8000
        case .x32: return 10023
        case .generic: return 8000
        }
    }

    /// Port on which the device answers (for the connection test), if it can answer.
    public var replyPort: UInt16? {
        switch self {
        case .eos: return 8001
        case .x32: return nil // answers to the sender's own port
        default: return nil
        }
    }

    /// Harmless message whose answer proves the link works (nil = the device does not answer).
    public var probe: OSCMessage? {
        switch self {
        case .eos: return OSCMessage("/eos/ping")
        case .x32: return OSCMessage("/info")
        default: return nil
        }
    }
}

public struct OSCDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: OSCDeviceKind
    public var host: String
    public var port: UInt16
    /// grandMA3 OSC prefix (set in the console's OSC line).
    public var prefix: String

    public init(id: UUID = UUID(), name: String, kind: OSCDeviceKind, host: String = "127.0.0.1", port: UInt16? = nil, prefix: String = "gma3") {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.prefix = prefix
    }
}

/// A parameter of a command template.
public struct OSCPresetField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case number, twoDigits, level, text }
    public var key: String
    public var kind: Kind
    public var defaultValue: String
}

/// A ready-made command for a device: the user fills in numbers, the address is built for them.
public struct OSCPreset: Equatable, Sendable {
    public var id: String
    public var fields: [OSCPresetField]
    /// Address with `{field}` placeholders (`{prefix}` = device prefix).
    public var address: String
    public var arguments: [String]

    /// Builds the message from field values ("{value}" in an argument = that field).
    public func message(_ values: [String: String], device: OSCDevice) -> OSCMessage {
        func fill(_ s: String) -> String {
            var out = s.replacingOccurrences(of: "{prefix}", with: device.prefix)
            for f in fields {
                var v = values[f.key] ?? f.defaultValue
                if f.kind == .twoDigits, let n = Int(v) { v = String(format: "%02d", n) }
                out = out.replacingOccurrences(of: "{\(f.key)}", with: v)
            }
            return out
        }
        let args: [OSCArgument] = arguments.map { template in
            let kind = fields.first { template == "{\($0.key)}" }?.kind
            let text = fill(template)
            if template.hasPrefix("i:") { return .int(Int32(fill(String(template.dropFirst(2)))) ?? 0) }
            if template.hasPrefix("f:") { return .float(Float(fill(String(template.dropFirst(2)))) ?? 0) }
            if kind == .level { return .float(Float(text) ?? 0) }
            if kind == .number || kind == .twoDigits { return .int(Int32(text) ?? 0) }
            return .string(text)
        }
        return OSCMessage(fill(address), args)
    }

    /// Typical commands per device. Addresses follow each product's published OSC documentation
    /// for current versions; the UI says where to look an address up if a version differs.
    public static func presets(for kind: OSCDeviceKind) -> [OSCPreset] {
        let n = { (k: String, d: String) in OSCPresetField(key: k, kind: .number, defaultValue: d) }
        let t = { (k: String, d: String) in OSCPresetField(key: k, kind: .text, defaultValue: d) }
        switch kind {
        case .resolume:
            return [
                OSCPreset(id: "resolume.clip", fields: [n("layer", "1"), n("clip", "1")],
                          address: "/composition/layers/{layer}/clips/{clip}/connect", arguments: ["i:1"]),
                OSCPreset(id: "resolume.column", fields: [n("column", "1")],
                          address: "/composition/columns/{column}/connect", arguments: ["i:1"]),
                OSCPreset(id: "resolume.clear", fields: [n("layer", "1")],
                          address: "/composition/layers/{layer}/clear", arguments: ["i:1"]),
                OSCPreset(id: "resolume.opacity", fields: [n("layer", "1"), OSCPresetField(key: "value", kind: .level, defaultValue: "1")],
                          address: "/composition/layers/{layer}/video/opacity", arguments: ["{value}"]),
            ]
        case .eos:
            return [
                OSCPreset(id: "eos.cue", fields: [n("list", "1"), n("cue", "1")], address: "/eos/cue/{list}/{cue}/fire", arguments: []),
                OSCPreset(id: "eos.go", fields: [], address: "/eos/key/go_0", arguments: []),
                OSCPreset(id: "eos.macro", fields: [n("macro", "1")], address: "/eos/macro/{macro}/fire", arguments: []),
                OSCPreset(id: "eos.cmd", fields: [t("text", "Chan 1 Full#")], address: "/eos/newcmd", arguments: ["{text}"]),
            ]
        case .grandMA3:
            return [
                OSCPreset(id: "ma3.go", fields: [n("sequence", "1")], address: "/{prefix}/cmd", arguments: ["Go+ Sequence {sequence}"]),
                OSCPreset(id: "ma3.cue", fields: [n("sequence", "1"), n("cue", "1")], address: "/{prefix}/cmd",
                          arguments: ["Goto Sequence {sequence} Cue {cue}"]),
                OSCPreset(id: "ma3.off", fields: [n("sequence", "1")], address: "/{prefix}/cmd", arguments: ["Off Sequence {sequence}"]),
                OSCPreset(id: "ma3.cmd", fields: [t("text", "Go+ Sequence 1")], address: "/{prefix}/cmd", arguments: ["{text}"]),
            ]
        case .magicQ:
            return [
                OSCPreset(id: "magicq.go", fields: [n("playback", "1")], address: "/pb/{playback}/go", arguments: []),
                OSCPreset(id: "magicq.release", fields: [n("playback", "1")], address: "/pb/{playback}/release", arguments: []),
            ]
        case .x32:
            return [
                OSCPreset(id: "x32.mute", fields: [OSCPresetField(key: "channel", kind: .twoDigits, defaultValue: "1")],
                          address: "/ch/{channel}/mix/on", arguments: ["i:0"]),
                OSCPreset(id: "x32.unmute", fields: [OSCPresetField(key: "channel", kind: .twoDigits, defaultValue: "1")],
                          address: "/ch/{channel}/mix/on", arguments: ["i:1"]),
                OSCPreset(id: "x32.fader", fields: [OSCPresetField(key: "channel", kind: .twoDigits, defaultValue: "1"),
                                                    OSCPresetField(key: "value", kind: .level, defaultValue: "0.75")],
                          address: "/ch/{channel}/mix/fader", arguments: ["{value}"]),
            ]
        case .generic:
            return []
        }
    }
}

/// A Network (OSC) cue: device and message; `preset` / `values` remember how it was built.
public struct OSCCueParams: Codable, Equatable, Sendable {
    public var device: UUID?
    public var preset: String?
    public var values: [String: String] = [:]
    public var address: String = "/"
    public var arguments: [OSCArgument] = []

    public init() {}

    public var message: OSCMessage { OSCMessage(address, arguments) }
}

// MARK: - Network helpers

public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    /// Whether `host` is on one of the local networks (address + mask), or is this machine.
    public static func reachableDirectly(_ host: String, interfaces: [(address: String, mask: String)]) -> Bool? {
        guard let h = parse(host) else { return nil } // a name: cannot tell
        if h >> 24 == 127 { return true }
        for i in interfaces {
            guard let a = parse(i.address), let m = parse(i.mask) else { continue }
            if a & m == h & m { return true }
        }
        return false
    }
}
