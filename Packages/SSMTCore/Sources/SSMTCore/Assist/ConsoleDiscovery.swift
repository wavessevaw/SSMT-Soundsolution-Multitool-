import Foundation

/// A console found on the network (Behringer X32 / Midas M32, X Air / MR answer "/xinfo").
public struct DiscoveredConsole: Equatable, Hashable, Identifiable, Sendable {
    public var family: MixerFamily
    public var ip: String
    public var name: String
    public var model: String
    public var firmware: String
    public var id: String { "\(family.rawValue)-\(ip)" }

    public init(family: MixerFamily, ip: String, name: String, model: String, firmware: String) {
        self.family = family; self.ip = ip; self.name = name; self.model = model; self.firmware = firmware
    }
}

/// Discovery as remote-control apps do it: "/xinfo" broadcast to UDP 10023 (X32 / M32) or 10024
/// (X Air / MR); every console answers "/xinfo ,ssss <ip> <name> <model> <firmware>".
public enum ConsoleDiscovery {
    public static let request = OSCMessage("/xinfo")

    /// Parses an answer. `sender` is the address the packet came from (used when the console leaves its IP empty).
    public static func parse(_ m: OSCMessage, sender: String, family: MixerFamily) -> DiscoveredConsole? {
        guard m.address == "/xinfo" else { return nil }
        let s = m.arguments.compactMap { a -> String? in if case let .string(v) = a { return v } else { return nil } }
        guard s.count >= 3 else { return nil }
        let ip = s[0].isEmpty || s[0] == "0.0.0.0" ? sender : s[0]
        let model = s[2]
        // The model tells the family when both ports answer (an M32 or XR18 on its own port).
        let fam: MixerFamily = model.uppercased().hasPrefix("XR") || model.uppercased().hasPrefix("MR") || model.uppercased().hasPrefix("X18")
            ? .xAir : (model.uppercased().hasPrefix("X32") || model.uppercased().hasPrefix("M32") ? .x32 : family)
        return DiscoveredConsole(family: fam, ip: ip, name: s[1], model: model, firmware: s.count > 3 ? s[3] : "")
    }
}
