import Foundation
import SSMTCore

// Qtrl's OSC (App/SSMT/Show/OSCHub.swift): sending to show devices, the incoming monitor, connection tests and the
// network hints. The engine opens no socket: "oscSend" / "oscListen" / "oscUnlisten" / "netInterfaces" events are
// carried by Electron's main process (src/engine-link.js), which answers with "oscIn", "oscListenError" and
// "netInterfaces" commands.

/// One received OSC message (monitor and connection tests).
struct ShowOSCEntry {
    let id = UUID()
    let time: Date
    let from: String
    let message: OSCMessage
}

final class ShowOSCHub {
    var log: [ShowOSCEntry] = []
    var listening: UInt16?
    var listenError: String?
    /// IPv4 addresses of this computer (without loopback).
    var interfaces: [(name: String, address: String, mask: String)] = []
    /// Connection tests waiting for an answer.
    var waiters: [(device: UUID, match: (OSCMessage) -> Bool, deadline: Date)] = []
    /// Test result by device id: "testing", "answered", "noAnswer".
    var test: [String: String] = [:]
    /// Address typed in the device setup, checked against the local networks.
    var draftHost = ""
    var dirty = true
}

extension ShowModule {
    func oscSend(_ message: OSCMessage, to device: OSCDevice) {
        Out.emit("oscSend", ["host": device.host, "port": Int(device.port), "data": message.encoded().base64EncodedString()])
    }

    /// Commands from Electron's main process.
    func oscCommand(_ c: Command) {
        switch c.name {
        case "oscIn":
            if let b = c.str("data"), let data = Data(base64Encoded: b), let msgs = OSCMessage.decode(data) {
                for m in msgs { received(m, from: c.str("from") ?? "?") }
            }
        case "oscListenError":
            osc.listenError = c.str("detail") ?? "error"
            osc.listening = nil
            osc.dirty = true
        case "netInterfaces":
            let items = c.fields["items"] as? [[String: Any]] ?? []
            osc.interfaces = items.compactMap { (i: [String: Any]) -> (name: String, address: String, mask: String)? in
                guard let a = i["address"] as? String, let m = i["mask"] as? String else { return nil }
                return (name: i["name"] as? String ?? "", address: a, mask: m)
            }
            osc.dirty = true
        default: break
        }
    }

    /// The OSC devices window and the inspector's Network cue.
    func oscOp(_ op: String, _ c: Command) -> Bool {
        switch op {
        case "oscListen": listen(on: UInt16(clamping: c.int("port") ?? 53535))
        case "oscStopListening": stopListening()
        case "oscClear": osc.log.removeAll(); osc.dirty = true
        case "oscTest": if let d = c.decode(OSCDevice.self, "device") { test(d) }
        case "oscTestSend":
            if let d = c.decode(OSCDevice.self, "device"), let first = OSCPreset.presets(for: d.kind).first {
                oscSend(first.message([:], device: d), to: d)
            }
        case "oscRefresh": Out.emit("netInterfaces"); osc.dirty = true
        case "oscDraftHost": osc.draftHost = c.str("host") ?? ""; osc.dirty = true
        default: return false
        }
        return true
    }

    func listen(on port: UInt16) {
        stopListening()
        Out.emit("oscListen", ["port": Int(port)])
        osc.listening = port
        osc.listenError = nil
        osc.dirty = true
    }

    func stopListening() {
        if osc.listening != nil { Out.emit("oscUnlisten") }
        osc.listening = nil
        osc.dirty = true
    }

    private func received(_ m: OSCMessage, from host: String) {
        osc.log.append(ShowOSCEntry(time: Date(), from: host, message: m))
        if osc.log.count > 300 { osc.log.removeFirst(osc.log.count - 300) }
        for (i, w) in osc.waiters.enumerated().reversed() where w.match(m) {
            osc.test[w.device.uuidString] = "answered"
            osc.waiters.remove(at: i)
        }
        osc.dirty = true
    }

    /// Sends the device's probe and waits up to 2 s for its answer.
    func test(_ device: OSCDevice) {
        guard let probe = device.kind.probe else { return }
        if let reply = device.kind.replyPort, osc.listening != reply { listen(on: reply) }
        let match: (OSCMessage) -> Bool
        switch device.kind {
        case .eos: match = { $0.address.hasPrefix("/eos/out/ping") }
        case .x32: match = { $0.address.hasPrefix("/info") }
        default: match = { _ in true }
        }
        oscSend(probe, to: device)
        osc.waiters.append((device: device.id, match: match, deadline: Date().addingTimeInterval(2)))
        osc.test[device.id.uuidString] = "testing"
        osc.dirty = true
    }

    func oscTick(_ now: Date) {
        for (i, w) in osc.waiters.enumerated().reversed() where now >= w.deadline {
            osc.test[w.device.uuidString] = "noAnswer"
            osc.waiters.remove(at: i)
            osc.dirty = true
        }
        if osc.dirty { osc.dirty = false; emitOSC() }
    }

    func subnetOK(_ host: String) -> Bool? {
        IPv4.reachableDirectly(host, interfaces: osc.interfaces.map { ($0.address, $0.mask) })
    }

    func emitOSC() {
        var subnet: [String: Any] = [:]
        for d in doc.devices { subnet[d.id.uuidString] = showOpt(subnetOK(d.host)) }
        let ms = { (d: Date) -> Double in (d.timeIntervalSince1970 * 1000).rounded() }
        Out.emit("showOSC", [
            "log": osc.log.map { e -> [String: Any] in ["id": e.id.uuidString, "time": ms(e.time), "from": e.from, "text": e.message.display] },
            "listening": showOpt(osc.listening.map { Int($0) }),
            "listenError": showOpt(osc.listenError),
            "interfaces": osc.interfaces.map { ["name": $0.name, "address": $0.address, "mask": $0.mask] },
            "subnet": subnet,
            "draftHost": osc.draftHost,
            "draftSubnet": showOpt(subnetOK(osc.draftHost)),
            "test": osc.test,
        ])
    }

    // MARK: Network cues

    /// Sends a Network cue's message now (inspector "Send now").
    func sendNow(_ cue: Cue) {
        guard let p = cue.osc, let id = p.device, let d = doc.devices.first(where: { $0.id == id }) else { return }
        oscSend(p.message, to: d)
    }

    /// A ready-made command chosen for a Network cue ("" = own address and arguments).
    func applyPreset(_ cueID: UUID, _ id: String) {
        guard let cue = doc.cue(cueID), let devID = cue.osc?.device, let device = doc.devices.first(where: { $0.id == devID }) else { return }
        updateCue(cueID) { c in
            guard var o = c.osc else { return }
            o.preset = id.isEmpty ? nil : id
            if let preset = OSCPreset.presets(for: device.kind).first(where: { $0.id == id }) {
                let m = preset.message(o.values, device: device)
                o.address = m.address
                o.arguments = m.arguments
                if c.name.isEmpty || c.name.hasPrefix("/") { c.name = "" }
            }
            c.osc = o
        }
    }

    /// A field of the chosen command (layer, cue, level…): the message is built again.
    func presetField(_ cueID: UUID, key: String, value: String) {
        guard let cue = doc.cue(cueID), let p = cue.osc, let devID = p.device,
              let device = doc.devices.first(where: { $0.id == devID }),
              let preset = OSCPreset.presets(for: device.kind).first(where: { $0.id == p.preset }) else { return }
        updateCue(cueID) { c in
            guard var o = c.osc else { return }
            o.values[key] = value
            let m = preset.message(o.values, device: device)
            o.address = m.address
            o.arguments = m.arguments
            c.osc = o
        }
    }

    /// Creates a Network cue from a message seen in the monitor (device chosen by sender address).
    func addNetworkCue(from entry: ShowOSCEntry) {
        guard let lid = listID else { return }
        var c = Cue(kind: .network, number: doc.nextCueNumber)
        c.osc?.address = entry.message.address
        c.osc?.arguments = entry.message.arguments
        c.osc?.device = doc.devices.first { $0.host == entry.from }?.id ?? doc.devices.first?.id
        c.name = entry.message.address
        let anchor = lastSelected
        let new = c
        edit { $0.insert([new], after: anchor, list: lid) }
        selection = [c.id]
    }
}

/// A value for a JSON event: the value, or null.
func showOpt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
