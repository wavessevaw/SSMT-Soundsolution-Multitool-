import Foundation

/// Every parameter of an X32 / M32 or X Air console that learning mode reads: channels, aux inputs, FX returns,
/// mix buses, matrices, main outputs, DCAs, effects and head amps. Each address is queried without arguments (a read);
/// the console answers with the value and keeps pushing changes to a subscribed remote.
/// Addresses follow the public unofficial protocol descriptions (ASSUMPTIONS A106): one the console does not know
/// simply gets no answer.
public enum ConsoleTree {
    /// All parameter addresses of a family (simulator: the X32 tree).
    public static func addresses(_ family: MixerFamily) -> [String] {
        family == .xAir ? xAir : x32
    }

    static func two(_ n: Int) -> String { String(format: "%02d", n) }

    static func eq(_ p: String, bands: Int) -> [String] {
        ["\(p)/eq/on"] + (1...bands).flatMap { b in ["type", "f", "g", "q"].map { "\(p)/eq/\(b)/\($0)" } }
    }

    static func gate(_ p: String) -> [String] {
        ["on", "mode", "thr", "range", "attack", "hold", "release", "keysrc", "filter/on", "filter/type", "filter/f"]
            .map { "\(p)/gate/\($0)" }
    }

    static func dyn(_ p: String) -> [String] {
        ["on", "mode", "det", "env", "thr", "ratio", "knee", "mgain", "attack", "hold", "release", "pos", "keysrc", "mix",
         "auto", "filter/on", "filter/type", "filter/f"].map { "\(p)/dyn/\($0)" }
    }

    /// Sends to mixes 1…n: level and on for each, pan and type on the odd one of a pair.
    static func sends(_ p: String, _ n: Int, on: Bool = true) -> [String] {
        (1...n).flatMap { s -> [String] in
            let q = "\(p)/mix/\(two(s))"
            var a = ["\(q)/level"]
            if on { a.append("\(q)/on") }
            if s % 2 == 1 { a += ["\(q)/pan", "\(q)/type"] }
            return a
        }
    }

    static func config(_ p: String, _ extra: [String] = []) -> [String] {
        (["name", "icon", "color"] + extra).map { "\(p)/config/\($0)" }
    }

    // MARK: X32 / M32

    static let x32: [String] = {
        var a: [String] = []
        for c in 1...32 {
            let p = "/ch/\(two(c))"
            a += config(p, ["source"])
            a += ["\(p)/delay/on", "\(p)/delay/time"]
            a += ["trim", "invert", "hpon", "hpslope", "hpf"].map { "\(p)/preamp/\($0)" }
            a += gate(p) + dyn(p)
            a += ["\(p)/insert/on", "\(p)/insert/pos", "\(p)/insert/sel"]
            a += eq(p, bands: 4)
            a += ["on", "fader", "st", "pan", "mono", "mlevel"].map { "\(p)/mix/\($0)" } + sends(p, 16)
            a += ["\(p)/grp/dca", "\(p)/grp/mutegrp", "\(p)/automix/group", "\(p)/automix/weight"]
        }
        for c in 1...8 {
            let p = "/auxin/\(two(c))"
            a += config(p, ["source"]) + ["\(p)/preamp/trim", "\(p)/preamp/invert"] + eq(p, bands: 4)
            a += ["on", "fader", "st", "pan", "mono", "mlevel"].map { "\(p)/mix/\($0)" } + sends(p, 16)
            a += ["\(p)/grp/dca", "\(p)/grp/mutegrp"]
        }
        for c in 1...8 {
            let p = "/fxrtn/\(two(c))"
            a += config(p) + eq(p, bands: 4)
            a += ["on", "fader", "st", "pan", "mono", "mlevel"].map { "\(p)/mix/\($0)" } + sends(p, 16)
            a += ["\(p)/grp/dca", "\(p)/grp/mutegrp"]
        }
        for b in 1...16 {
            let p = "/bus/\(two(b))"
            a += config(p) + dyn(p) + ["\(p)/insert/on", "\(p)/insert/pos", "\(p)/insert/sel"] + eq(p, bands: 6)
            a += ["on", "fader", "st", "pan", "mono", "mlevel"].map { "\(p)/mix/\($0)" } + sends(p, 6)
            a += ["\(p)/grp/dca", "\(p)/grp/mutegrp"]
        }
        for m in 1...6 {
            let p = "/mtx/\(two(m))"
            a += config(p) + ["\(p)/preamp/invert"] + dyn(p) + ["\(p)/insert/on", "\(p)/insert/pos", "\(p)/insert/sel"]
            a += eq(p, bands: 6) + ["\(p)/mix/on", "\(p)/mix/fader"]
        }
        for p in ["/main/st", "/main/m"] {
            a += config(p) + dyn(p) + ["\(p)/insert/on", "\(p)/insert/pos", "\(p)/insert/sel"] + eq(p, bands: 6)
            a += ["\(p)/mix/on", "\(p)/mix/fader"] + (p == "/main/st" ? ["\(p)/mix/pan"] : []) + sends(p, 6)
        }
        for d in 1...8 { a += ["/dca/\(d)/on", "/dca/\(d)/fader", "/dca/\(d)/config/name", "/dca/\(d)/config/color"] }
        for f in 1...8 {
            a += ["/fx/\(f)/type", "/fx/\(f)/source/l", "/fx/\(f)/source/r"] + (1...64).map { "/fx/\(f)/par/\(two($0))" }
        }
        for h in 0...127 { a += [String(format: "/headamp/%03d/gain", h), String(format: "/headamp/%03d/phantom", h)] }
        a += X32InputRouting.blockAddresses
        a += ["/-stat/selidx", "/-stat/rta/source", "/-stat/solosw/01"]
        return a
    }()

    // MARK: X Air / MR

    static let xAir: [String] = {
        var a: [String] = []
        for c in 1...16 {
            let p = "/ch/\(two(c))"
            a += ["name", "color", "insrc", "rtnsrc"].map { "\(p)/config/\($0)" }
            a += ["hpon", "hpf", "hpslope", "invert", "rtnsw"].map { "\(p)/preamp/\($0)" }
            a += gate(p) + dyn(p) + ["\(p)/insert/on", "\(p)/insert/sel"] + eq(p, bands: 4)
            a += ["\(p)/mix/on", "\(p)/mix/fader", "\(p)/mix/lr", "\(p)/mix/pan"] + sends(p, 10, on: false)
            a += ["\(p)/grp/dca", "\(p)/grp/mute", "\(p)/automix/group", "\(p)/automix/weight"]
        }
        for p in ["/rtn/aux"] + (1...4).map({ "/rtn/\($0)" }) {
            a += ["\(p)/config/name", "\(p)/config/color", "\(p)/preamp/gain"] + eq(p, bands: 4)
            a += ["\(p)/mix/on", "\(p)/mix/fader", "\(p)/mix/lr", "\(p)/mix/pan"] + sends(p, 10, on: false)
            a += ["\(p)/grp/dca", "\(p)/grp/mute"]
        }
        for b in 1...6 {
            let p = "/bus/\(b)"
            a += ["\(p)/config/name", "\(p)/config/color"] + dyn(p) + ["\(p)/insert/on", "\(p)/insert/sel"] + eq(p, bands: 6)
            a += ["\(p)/mix/on", "\(p)/mix/fader", "\(p)/mix/lr", "\(p)/mix/pan", "\(p)/grp/dca", "\(p)/grp/mute"]
        }
        for f in 1...4 {
            let p = "/fxsend/\(f)"
            a += ["\(p)/config/name", "\(p)/mix/on", "\(p)/mix/fader", "\(p)/grp/dca", "\(p)/grp/mute"]
        }
        a += ["/lr/config/name"] + dyn("/lr") + ["/lr/insert/on", "/lr/insert/sel"] + eq("/lr", bands: 6)
        a += ["/lr/mix/on", "/lr/mix/fader", "/lr/mix/pan"]
        for d in 1...4 { a += ["/dca/\(d)/on", "/dca/\(d)/fader", "/dca/\(d)/config/name", "/dca/\(d)/config/color"] }
        for f in 1...4 { a += ["/fx/\(f)/type", "/fx/\(f)/insert"] + (1...64).map { "/fx/\(f)/par/\(two($0))" } }
        for h in 1...24 { a += [String(format: "/headamp/%02d/gain", h), String(format: "/headamp/%02d/phantom", h)] }
        a += ["/-stat/selidx", "/-stat/rta/source", "/-stat/solosw/01"]
        return a
    }()
}
