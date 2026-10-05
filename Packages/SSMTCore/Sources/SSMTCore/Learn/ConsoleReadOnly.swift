import Foundation

/// Learning mode listens to the console and never changes it. Every message bound for a real console in this mode
/// passes through `allows`: queries (an address with no arguments), the parameter subscription and meter requests
/// get through; anything that would set a value is dropped.
public enum ConsoleReadOnly {
    /// Addresses that take a string argument without changing anything on the console (meter subscriptions).
    static let requestAddresses: Set<String> = ["/meters", "/batchsubscribe", "/formatsubscribe", "/subscribe", "/renew"]

    /// True when sending `m` cannot change the console.
    public static func allows(_ m: OSCMessage) -> Bool {
        if m.arguments.isEmpty { return true }
        guard requestAddresses.contains(m.address) else { return false }
        return m.arguments.allSatisfy { if case .string = $0 { return true } else { return false } }
    }

    /// The messages of `messages` that may go to the console in learning mode.
    public static func filter(_ messages: [OSCMessage]) -> [OSCMessage] { messages.filter(allows) }

    /// Everything learning mode asks the console for when it connects: identification, the update subscription,
    /// the meter streams, the input routing (X32) and every channel strip and mix bus.
    public static func connectRequests(family: MixerFamily, routing: X32InputRouting) -> [OSCMessage] {
        var a: [String] = []
        if family != .xAir {
            a += X32InputRouting.blockAddresses + (1...family.channelCount).map { X32Codec.channelPath($0) + "/config/source" }
        }
        a += (1...family.channelCount).flatMap { X32Codec.queryAddresses($0, family: family, routing: routing) }
        a += (1...X32Codec.busCount(family)).flatMap { X32Codec.busQueryAddresses($0, family: family) }
        return [X32Codec.info] + renewals(family: family) + a.map { OSCMessage($0) }
    }

    /// Repeated every few seconds: the console forgets a remote and stops its meters after 10 s.
    public static func renewals(family: MixerFamily) -> [OSCMessage] {
        [X32Codec.subscribe(family: family)] + [ConsoleMeters.Bank.channels, .buses].map { ConsoleMeters.request($0, family: family) }
    }
}
