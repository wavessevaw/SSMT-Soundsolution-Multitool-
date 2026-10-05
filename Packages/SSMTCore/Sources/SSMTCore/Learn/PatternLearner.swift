import Foundation

/// How the engineer sets one kind of source, learned from the recordings.
public struct SourcePattern: Codable, Equatable, Sendable {
    public struct Band: Codable, Equatable, Sendable {
        /// Console band 1…4.
        public var band: Int
        /// Share of the channels where this band was moved away from 0 dB.
        public var share: Double
        public var frequency: Double
        public var gainDB: Double
    }

    public var kind: SourceKind
    /// Channels of this kind over all recordings (one per channel per event).
    public var channels: Int
    /// Minutes with signal on these channels.
    public var activeMinutes: Double
    public var gainDB: Double?
    /// Fader while the channel is playing.
    public var faderDB: Double?
    /// Channel meter while playing (dBFS).
    public var levelDB: Double?
    public var highPassShare: Double
    public var highPassHz: Double?
    public var eq: [Band]
    public var compressorShare: Double
    public var thresholdDB: Double?
    public var ratio: Double?
    /// Fader moves (≥ 0.5 dB in a second) per minute of playing.
    public var ridesPerMinute: Double
}

/// What the recordings taught so far.
public struct LearnedPatterns: Codable, Equatable, Sendable {
    /// Recordings long enough to count as an event.
    public var events: Int
    public var hours: Double
    public var sources: [SourcePattern]

    /// Learning target: about this many events before a soundcheck engine is built on the patterns.
    public static let targetEvents = 20

    public var progress: Double { min(1, Double(events) / Double(Self.targetEvents)) }
    public var ready: Bool { events >= Self.targetEvents }

    /// Plain-text summary (also the facts the language model is given).
    public func summary(russian: Bool) -> String {
        var out: [String] = []
        out.append(russian
            ? String(format: "Записано мероприятий: %d из %d, всего %.1f ч.", events, Self.targetEvents, hours)
            : String(format: "Events recorded: %d of %d, %.1f h in total.", events, Self.targetEvents, hours))
        for p in sources {
            var parts: [String] = []
            func num(_ v: Double?, _ fmt: String) { if let v { parts.append(String(format: fmt, v)) } }
            num(p.gainDB, russian ? "гейн %.0f дБ" : "gain %.0f dB")
            num(p.faderDB, russian ? "фейдер %.1f дБ" : "fader %.1f dB")
            num(p.levelDB, russian ? "уровень %.0f dBFS" : "level %.0f dBFS")
            if p.highPassShare >= 0.5, let hz = p.highPassHz {
                parts.append(String(format: russian ? "обрезной фильтр %.0f Гц (%.0f%%)" : "high-pass %.0f Hz (%.0f%%)", hz, p.highPassShare * 100))
            }
            for b in p.eq where b.share >= 0.4 {
                parts.append(String(format: russian ? "EQ%d %+.1f дБ на %.0f Гц" : "EQ%d %+.1f dB at %.0f Hz", b.band, b.gainDB, b.frequency))
            }
            if p.compressorShare >= 0.5, let thr = p.thresholdDB, let ratio = p.ratio {
                parts.append(String(format: russian ? "компрессор %.0f дБ, %.1f:1" : "compressor %.0f dB, %.1f:1", thr, ratio))
            }
            parts.append(String(format: russian ? "движений фейдера %.1f в мин" : "fader rides %.1f per min", p.ridesPerMinute))
            let name = SourcePattern.displayName(p.kind, russian: russian)
            out.append("• \(name) (\(p.channels)): " + parts.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }

    /// Text for a small language model: the learned facts and the engineer's question.
    public func prompt(question: String, russian: Bool) -> String {
        let intro = russian
            ? "Ты помощник звукорежиссёра за пультом (FOH). Ниже закономерности, которые программа SSMT нашла в записях пульта на прошедших мероприятиях этого звукорежиссёра. Отвечай кратко, по-русски, только на основе этих данных; если данных мало, так и скажи."
            : "You assist a front-of-house sound engineer. Below are the patterns SSMT found in console recordings of this engineer's past events. Answer briefly, only from these data; if there is too little data, say so."
        let q = russian ? "Вопрос" : "Question"
        return "\(intro)\n\n\(summary(russian: russian))\n\n\(q): \(question)"
    }
}

extension SourcePattern {
    public static func displayName(_ k: SourceKind, russian: Bool) -> String {
        let names: [SourceKind: (String, String)] = [
            .kick: ("Kick", "Бочка"), .snare: ("Snare", "Малый барабан"), .tom: ("Tom", "Том"), .hiHat: ("Hi-hat", "Хай-хэт"),
            .overhead: ("Overheads", "Overhead"), .percussion: ("Percussion", "Перкуссия"),
            .bassGuitar: ("Bass", "Бас"), .electricGuitar: ("Electric guitar", "Электрогитара"),
            .acousticGuitar: ("Acoustic guitar", "Акустическая гитара"), .keys: ("Keys", "Клавиши"), .piano: ("Piano", "Рояль"),
            .maleVocal: ("Male vocal", "Мужской вокал"), .femaleVocal: ("Female vocal", "Женский вокал"),
            .backingVocal: ("Backing vocal", "Бэк-вокал"), .choir: ("Choir", "Хор"), .speech: ("Speech", "Речь"),
            .violin: ("Violin", "Скрипка"), .viola: ("Viola", "Альт"), .cello: ("Cello", "Виолончель"),
            .doubleBass: ("Double bass", "Контрабас"), .harp: ("Harp", "Арфа"), .flute: ("Flute", "Флейта"),
            .clarinet: ("Clarinet", "Кларнет"), .oboe: ("Oboe", "Гобой"), .bassoon: ("Bassoon", "Фагот"),
            .saxophone: ("Saxophone", "Саксофон"), .trumpet: ("Trumpet", "Труба"), .trombone: ("Trombone", "Тромбон"),
            .frenchHorn: ("French horn", "Валторна"), .tuba: ("Tuba", "Туба"), .playback: ("Playback", "Фонограмма"),
            .unknown: ("Other channels", "Прочие каналы"),
        ]
        let n = names[k] ?? (k.rawValue, k.rawValue)
        return russian ? n.1 : n.0
    }
}

/// Finds the patterns in a set of recordings: for each kind of source (read from the channel names), the gain, fader,
/// filter, EQ and compressor the engineer used and how often the fader was ridden. Per channel and event the median is
/// taken first, so one long show does not outweigh the others.
public enum PatternLearner {
    /// A channel is "playing" above this meter level, unmuted and with the fader up.
    public static let activeDB = -60.0
    /// A recording shorter than this is a test, not an event.
    public static let minEventSeconds = 300.0

    struct ChannelAccumulator {
        var name = ""
        var gain: [Double] = [], fader: [Double] = [], level: [Double] = []
        var hpfOn = 0, hpfHz: [Double] = [], samples = 0
        var eqUsed = [Int](repeating: 0, count: 4)
        var eqFreq: [[Double]] = Array(repeating: [], count: 4), eqGain: [[Double]] = Array(repeating: [], count: 4)
        var compOn = 0, threshold: [Double] = [], ratio: [Double] = []
        var active = 0, rides = 0
        var lastFader: Double?
    }

    struct KindAccumulator {
        var channels = 0, activeSeconds = 0.0
        var gain: [Double] = [], fader: [Double] = [], level: [Double] = []
        var hpfShare: [Double] = [], hpfHz: [Double] = []
        var eqShare: [[Double]] = Array(repeating: [], count: 4)
        var eqFreq: [[Double]] = Array(repeating: [], count: 4), eqGain: [[Double]] = Array(repeating: [], count: 4)
        var compShare: [Double] = [], threshold: [Double] = [], ratio: [Double] = []
        var rides = 0, rideMinutes = 0.0
    }

    public static func learn(_ recordings: [LearnRecording]) -> LearnedPatterns {
        var kinds: [SourceKind: KindAccumulator] = [:]
        var events = 0
        var seconds = 0.0
        for rec in recordings {
            if rec.duration >= minEventSeconds { events += 1 }
            seconds += rec.duration
            var acc: [Int: ChannelAccumulator] = [:]
            rec.replay { frame, strips, _ in
                for (ch, s) in strips {
                    var a = acc[ch] ?? ChannelAccumulator()
                    if !s.name.isEmpty { a.name = s.name }
                    let level = ch - 1 < frame.levels.count ? frame.levels[ch - 1] : -120
                    let playing = level > activeDB && !s.muted && s.faderDB > -60
                    if playing {
                        a.active += 1
                        a.samples += 1
                        a.gain.append(s.gainDB)
                        a.fader.append(s.faderDB)
                        a.level.append(level)
                        if s.highPassOn { a.hpfOn += 1; a.hpfHz.append(s.highPassHz) }
                        if s.eqOn {
                            for (i, b) in s.eq.prefix(4).enumerated() where abs(b.gainDB) >= 0.5 {
                                a.eqUsed[i] += 1
                                a.eqFreq[i].append(b.frequency)
                                a.eqGain[i].append(b.gainDB)
                            }
                        }
                        if s.compressor.compressing {
                            a.compOn += 1
                            a.threshold.append(s.compressor.thresholdDB)
                            a.ratio.append(s.compressor.ratio)
                        }
                        if let lf = a.lastFader, abs(lf - s.faderDB) >= 0.5 { a.rides += 1 }
                    }
                    a.lastFader = s.faderDB
                    acc[ch] = a
                }
            }
            let names = acc.values.map(\.name)
            let choirContext = names.contains { SourceClassifier.kind(forName: $0) == .choir }
            for a in acc.values where a.samples >= 10 {
                let kind = SourceClassifier.kind(forName: a.name, choirContext: choirContext) ?? .unknown
                var k = kinds[kind] ?? KindAccumulator()
                let n = Double(a.samples)
                k.channels += 1
                k.activeSeconds += Double(a.active)
                if let v = median(a.gain) { k.gain.append(v) }
                if let v = median(a.fader) { k.fader.append(v) }
                if let v = median(a.level) { k.level.append(v) }
                k.hpfShare.append(Double(a.hpfOn) / n)
                if let v = median(a.hpfHz) { k.hpfHz.append(v) }
                for i in 0..<4 {
                    k.eqShare[i].append(Double(a.eqUsed[i]) / n)
                    if let v = median(a.eqFreq[i]) { k.eqFreq[i].append(v) }
                    if let v = median(a.eqGain[i]) { k.eqGain[i].append(v) }
                }
                k.compShare.append(Double(a.compOn) / n)
                if let v = median(a.threshold) { k.threshold.append(v) }
                if let v = median(a.ratio) { k.ratio.append(v) }
                k.rides += a.rides
                k.rideMinutes += Double(a.active) / 60
                kinds[kind] = k
            }
        }
        let sources = kinds.map { kind, k -> SourcePattern in
            SourcePattern(
                kind: kind, channels: k.channels, activeMinutes: k.activeSeconds / 60,
                gainDB: median(k.gain), faderDB: median(k.fader), levelDB: median(k.level),
                highPassShare: mean(k.hpfShare), highPassHz: median(k.hpfHz),
                eq: (0..<4).compactMap { i in
                    guard let f = median(k.eqFreq[i]), let g = median(k.eqGain[i]) else { return nil }
                    return SourcePattern.Band(band: i + 1, share: mean(k.eqShare[i]), frequency: f, gainDB: g)
                },
                compressorShare: mean(k.compShare), thresholdDB: median(k.threshold), ratio: median(k.ratio),
                ridesPerMinute: k.rideMinutes > 0 ? Double(k.rides) / k.rideMinutes : 0)
        }
        .sorted { ($0.kind == .unknown ? 1 : 0, -$0.channels, $0.kind.rawValue) < ($1.kind == .unknown ? 1 : 0, -$1.channels, $1.kind.rawValue) }
        return LearnedPatterns(events: events, hours: seconds / 3600, sources: sources)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
}
