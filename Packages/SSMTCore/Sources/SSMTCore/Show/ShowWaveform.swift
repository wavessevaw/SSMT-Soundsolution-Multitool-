import Foundation

/// Waveform pictures and sound bounds of decoded audio, for Qtrl's editors (the cue list, the timelines and the
/// waveform editor). The same code draws the macOS and the Windows program.
public enum ShowWaveform {
    /// Peak overview of a clip (all channels), `buckets` values in 0…1.
    public static func overview(_ clip: AudioClip, buckets: Int = 1200) -> [Float] {
        let n = clip.frames
        guard n > 0, buckets > 0 else { return [] }
        let size = max(1, n / buckets)
        var out = [Float](repeating: 0, count: min(buckets, n))
        for c in 0..<clip.channelCount {
            let p = clip.channel(c)
            for b in 0..<out.count {
                var peak: Float = 0
                let start = b * size, end = min(n, start + size)
                var i = start
                while i < end { peak = max(peak, abs(p[i])); i += 4 } // every 4th sample is plenty for display
                out[b] = max(out[b], min(1, peak))
            }
        }
        return out
    }

    /// Peaks of a file section (file seconds) in `buckets` columns; nil when the section is empty.
    public static func slice(_ clip: AudioClip, from: Double, to: Double, buckets: Int) -> [Float]? {
        let sr = clip.sampleRate
        guard buckets > 0, to > from else { return nil }
        let a = max(0, Int(from * sr)), b = min(clip.frames, Int(to * sr))
        guard b > a else { return nil }
        let per = Double(b - a) / Double(buckets)
        let stride = max(1, Int(per / 64)) // at most ~64 reads per column
        var out = [Float](repeating: 0, count: buckets)
        for c in 0..<clip.channelCount {
            let p = clip.channel(c)
            for k in 0..<buckets {
                let s = a + Int(Double(k) * per), e = min(b, a + Int(Double(k + 1) * per) + 1)
                var peak: Float = 0
                var i = s
                while i < e { peak = max(peak, abs(p[i])); i += stride }
                out[k] = max(out[k], min(1, peak))
            }
        }
        return out
    }

    /// "Trim silence": start and end (seconds) at the first and last sound above `threshold` (−50 dBFS), with
    /// 10 ms before and 50 ms after; nil when nothing is that loud.
    public static func soundBounds(_ clip: AudioClip, threshold: Float = 0.00316) -> (start: Double, end: Double)? {
        let sr = clip.sampleRate
        var first = clip.frames, last = 0
        for c in 0..<clip.channelCount {
            let ch = clip.channel(c)
            if let i = ch.firstIndex(where: { abs($0) > threshold }) { first = min(first, i) }
            if let i = ch.lastIndex(where: { abs($0) > threshold }) { last = max(last, i) }
        }
        guard first < last else { return nil }
        return (max(0, Double(first) / sr - 0.01), min(clip.duration, Double(last) / sr + 0.05))
    }
}

extension OSCArgument {
    /// Arguments typed as text: "1 0.5 \"Go+ Sequence 1\" true" → int, float, string, bool.
    public static func parseList(_ text: String) -> [OSCArgument] {
        var out: [OSCArgument] = []
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0 == " " }
            guard let c = rest.first else { break }
            if c == "\"" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                out.append(.string(String(body[..<end])))
                rest = end < body.endIndex ? body[body.index(after: end)...] : ""
                continue
            }
            let end = rest.firstIndex(of: " ") ?? rest.endIndex
            let token = String(rest[..<end])
            rest = rest[end...]
            if token == "true" || token == "false" { out.append(.bool(token == "true")) }
            else if let i = Int32(token) { out.append(.int(i)) }
            else if let f = Float(token) { out.append(.float(f)) }
            else { out.append(.string(token)) }
        }
        return out
    }
}
