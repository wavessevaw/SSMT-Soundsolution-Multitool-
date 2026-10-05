import Foundation

/// Sound engineering formulas used by the handbook calculators (SI units unless the name says otherwise).
public enum AudioMath {
    /// Speed of sound in air, m/s, at a temperature in °C.
    public static func speedOfSound(celsius: Double) -> Double { 331.3 * (1 + celsius / 273.15).squareRoot() }

    public static func dBu(volts: Double) -> Double { 20 * log10(max(volts, 1e-12) / 0.7746) }
    public static func dBV(volts: Double) -> Double { 20 * log10(max(volts, 1e-12)) }
    public static func volts(dBu: Double) -> Double { 0.7746 * pow(10, dBu / 20) }

    /// Level change from a source at `d1` to `d2`: point source −6 dB per doubling, line source −3 dB.
    public static func levelChange(from d1: Double, to d2: Double, lineSource: Bool = false) -> Double {
        (lineSource ? -10 : -20) * log10(max(d2, 1e-9) / max(d1, 1e-9))
    }

    /// SPL of a loudspeaker: sensitivity (dB SPL, 1 W / 1 m), power in W, distance in m.
    public static func spl(sensitivity: Double, watts: Double, meters: Double) -> Double {
        sensitivity + 10 * log10(max(watts, 1e-12)) - 20 * log10(max(meters, 1e-9))
    }

    /// Incoherent sum of levels in dB.
    public static func sum(dB levels: [Double]) -> Double {
        10 * log10(levels.reduce(0) { $0 + pow(10, $1 / 10) })
    }

    /// Total impedance of loads in series or in parallel.
    public static func impedance(_ loads: [Double], parallel: Bool) -> Double {
        let z = loads.filter { $0 > 0 }
        guard !z.isEmpty else { return 0 }
        return parallel ? 1 / z.reduce(0) { $0 + 1 / $1 } : z.reduce(0, +)
    }

    /// Resistance of a two-conductor copper speaker cable (there and back), Ω.
    public static func cableResistance(meters: Double, squareMillimetres: Double) -> Double {
        2 * meters * 0.0175 / max(squareMillimetres, 1e-6)
    }

    /// Level lost in the cable, dB (negative).
    public static func cableLoss(load: Double, cable: Double) -> Double { 20 * log10(load / (load + cable)) }

    /// Damping factor at the loudspeaker, with the amplifier's own damping factor.
    public static func dampingFactor(load: Double, cable: Double, amplifierDF: Double) -> Double {
        load / (load / max(amplifierDF, 1) + cable)
    }

    /// Axial room modes (Hz) along one dimension.
    public static func axialModes(length: Double, celsius: Double = 20, count: Int = 4) -> [Double] {
        (1...count).map { Double($0) * speedOfSound(celsius: celsius) / (2 * length) }
    }

    /// Reverberation time (s), Sabine: volume m³, surface m², average absorption coefficient.
    public static func rt60Sabine(volume: Double, surface: Double, absorption: Double) -> Double {
        0.161 * volume / max(surface * absorption, 1e-9)
    }

    /// Critical distance (m): directivity factor Q, volume m³, reverberation time s.
    public static func criticalDistance(q: Double, volume: Double, rt60: Double) -> Double {
        0.057 * (q * volume / max(rt60, 1e-9)).squareRoot()
    }

    /// Nearest equal-tempered note and the deviation in cents.
    public static func note(frequency: Double, a4: Double = 440) -> (name: String, octave: Int, cents: Double) {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let semis = 12 * log2(max(frequency, 1e-9) / a4) + 57 // semitones above C0
        let n = Int(semis.rounded())
        let cents = (semis - Double(n)) * 100
        let idx = ((n % 12) + 12) % 12
        let octave = Int(floor(Double(n) / 12))
        return (names[idx], octave, cents)
    }
}

/// One calculator: input fields and a function that turns their values into results.
public struct AudioCalculator: Identifiable, Sendable {
    public struct Field: Identifiable, Sendable {
        public enum Kind: Sendable {
            case number(unit: String, min: Double, max: Double)
            /// Index into the options, stored as a number.
            case choice([LText])
        }
        public var id: String
        public var label: LText
        public var kind: Kind
        public var initial: Double
        public init(_ id: String, _ label: LText, unit: String = "", initial: Double, min: Double = 0, max: Double = 1e9) {
            self.id = id
            self.label = label
            kind = .number(unit: unit, min: min, max: max)
            self.initial = initial
        }
        public init(_ id: String, _ label: LText, options: [LText], initial: Int = 0) {
            self.id = id
            self.label = label
            kind = .choice(options)
            self.initial = Double(initial)
        }
    }

    public struct Result: Hashable, Sendable {
        public var label: LText
        public var value: String
        public var unit: String
        /// The main answer is shown large.
        public var primary: Bool
        public init(_ label: LText, _ value: Double, _ unit: String = "", digits: Int = 1, primary: Bool = false) {
            self.label = label
            self.value = value.isFinite ? AudioCalculator.format(value, digits: digits) : "—"
            self.unit = unit
            self.primary = primary
        }
        public init(_ label: LText, text: String, primary: Bool = false) {
            self.label = label
            value = text
            unit = ""
            self.primary = primary
        }
    }

    public var id: String
    public var title: LText
    public var subtitle: LText
    public var icon: String
    public var tags: [String]
    public var fields: [Field]
    /// How it is calculated (shown under the results).
    public var formula: LText
    public var compute: @Sendable ([String: Double]) -> [Result]

    public init(_ id: String, title: LText, subtitle: LText, icon: String, tags: [String] = [], fields: [Field],
                formula: LText, compute: @escaping @Sendable ([String: Double]) -> [Result]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tags = tags
        self.fields = fields
        self.formula = formula
        self.compute = compute
    }

    public var initialValues: [String: Double] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.initial) })
    }

    /// Results for the given values; missing fields take their initial values.
    public func results(_ values: [String: Double]) -> [Result] {
        compute(initialValues.merging(values) { _, new in new })
    }

    public func matches(_ query: String, russian: Bool) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let text = ([title.ru, title.en, subtitle.text(russian: russian), formula.text(russian: russian)] + tags)
            .joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }

    /// Up to `digits` decimals, trailing zeros dropped ("2.50" → "2.5", "3.00" → "3"). No formatter object: this
    /// runs on every keystroke for every result.
    static func format(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(max(0, digits))f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }
}

extension AudioCalculator {
    public static func search(_ query: String, russian: Bool) -> [AudioCalculator] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? all : all.filter { $0.matches(query, russian: russian) }
    }

    private static let temp = Field("t", LText("Температура воздуха", "Air temperature"), unit: "°C", initial: 20, min: -30, max: 50)

    public static let all: [AudioCalculator] = [
        AudioCalculator("delay", title: LText("Задержка по расстоянию", "Delay from distance"),
                        subtitle: LText("Выравнивание порталов, дилеев, сабов", "Aligning mains, delays, subs"),
                        icon: "timer", tags: ["delay", "задержка", "ms", "мс", "дилей", "выравнивание"],
                        fields: [Field("d", LText("Расстояние", "Distance"), unit: "m", initial: 30, max: 2000), temp,
                                 Field("haas", LText("Добавить (эффект предшествования)", "Add (precedence)"), unit: "ms", initial: 0, max: 50)],
                        formula: LText("t = d / c, c = 331,3·√(1 + T/273,15). Для дилей-линии обычно добавляют 5–15 мс, чтобы звук «шёл» со сцены.",
                                       "t = d / c, c = 331.3·√(1 + T/273.15). Delay lines usually get 5–15 ms extra so the sound stays on stage.")) { v in
            let c = AudioMath.speedOfSound(celsius: v["t"]!)
            let ms = v["d"]! / c * 1000 + v["haas"]!
            return [Result(LText("Задержка", "Delay"), ms, "ms", digits: 2, primary: true),
                    Result(LText("Скорость звука", "Speed of sound"), c, "m/s"),
                    Result(LText("Сэмплов при 48 кГц", "Samples at 48 kHz"), ms * 48, digits: 0),
                    Result(LText("Сэмплов при 96 кГц", "Samples at 96 kHz"), ms * 96, digits: 0)]
        },
        AudioCalculator("distanceFromDelay", title: LText("Расстояние по задержке", "Distance from delay"),
                        subtitle: LText("Сколько метров в миллисекундах", "How many metres in milliseconds"),
                        icon: "ruler", tags: ["distance", "расстояние", "ms"],
                        fields: [Field("ms", LText("Задержка", "Delay"), unit: "ms", initial: 10, max: 10_000), temp],
                        formula: LText("d = t · c. Около 34 см на миллисекунду при 20 °C.", "d = t · c. About 34 cm per millisecond at 20 °C.")) { v in
            let c = AudioMath.speedOfSound(celsius: v["t"]!)
            return [Result(LText("Расстояние", "Distance"), v["ms"]! / 1000 * c, "m", digits: 2, primary: true)]
        },
        AudioCalculator("wavelength", title: LText("Длина волны", "Wavelength"),
                        subtitle: LText("Частота ↔ длина волны, ¼ и ½ волны", "Frequency ↔ wavelength, ¼ and ½ wave"),
                        icon: "waveform", tags: ["wavelength", "длина волны", "frequency", "частота", "lambda"],
                        fields: [Field("f", LText("Частота", "Frequency"), unit: "Hz", initial: 100, min: 1, max: 40_000), temp],
                        formula: LText("λ = c / f", "λ = c / f")) { v in
            let l = AudioMath.speedOfSound(celsius: v["t"]!) / v["f"]!
            return [Result(LText("Длина волны", "Wavelength"), l, "m", digits: 3, primary: true),
                    Result(LText("½ волны", "½ wave"), l / 2, "m", digits: 3),
                    Result(LText("¼ волны", "¼ wave"), l / 4, "m", digits: 3),
                    Result(LText("Период", "Period"), 1000 / v["f"]!, "ms", digits: 3)]
        },
        AudioCalculator("splDistance", title: LText("Уровень на расстоянии", "Level at distance"),
                        subtitle: LText("Закон обратных квадратов, точечный и линейный источник", "Inverse square law, point and line source"),
                        icon: "speaker.wave.3", tags: ["spl", "inverse square", "обратных квадратов", "уровень", "distance"],
                        fields: [Field("l1", LText("Уровень в точке 1", "Level at point 1"), unit: "dB SPL", initial: 100, min: 0, max: 200),
                                 Field("d1", LText("Расстояние 1", "Distance 1"), unit: "m", initial: 1, min: 0.01, max: 10_000),
                                 Field("d2", LText("Расстояние 2", "Distance 2"), unit: "m", initial: 30, min: 0.01, max: 10_000),
                                 Field("src", LText("Источник", "Source"), options: [LText("Точечный (−6 дБ на удвоение)", "Point (−6 dB per doubling)"),
                                                                                    LText("Линейный (−3 дБ на удвоение)", "Line (−3 dB per doubling)")])],
                        formula: LText("L₂ = L₁ − 20·lg(d₂/d₁); для линейного источника (ближняя зона линейного массива) 10·lg.",
                                       "L₂ = L₁ − 20·log(d₂/d₁); 10·log for a line source (line array near field).")) { v in
            let ch = AudioMath.levelChange(from: v["d1"]!, to: v["d2"]!, lineSource: v["src"]! >= 1)
            return [Result(LText("Уровень в точке 2", "Level at point 2"), v["l1"]! + ch, "dB SPL", primary: true),
                    Result(LText("Изменение", "Change"), ch, "dB")]
        },
        AudioCalculator("speakerSPL", title: LText("Максимальный уровень колонки", "Loudspeaker maximum SPL"),
                        subtitle: LText("Чувствительность, мощность, расстояние", "Sensitivity, power, distance"),
                        icon: "hifispeaker", tags: ["spl", "sensitivity", "чувствительность", "мощность", "колонка", "звуковое давление"],
                        fields: [Field("s", LText("Чувствительность (1 Вт / 1 м)", "Sensitivity (1 W / 1 m)"), unit: "dB", initial: 98, min: 60, max: 130),
                                 Field("p", LText("Мощность", "Power"), unit: "W", initial: 500, min: 0.01, max: 100_000),
                                 Field("d", LText("Расстояние", "Distance"), unit: "m", initial: 10, min: 0.1, max: 2000),
                                 Field("n", LText("Колонок рядом (одинаковых)", "Boxes side by side (same)"), initial: 1, min: 1, max: 64)],
                        formula: LText("SPL = S + 10·lg P − 20·lg d; N колонок рядом складываются примерно как +10·lg N (некогерентно) … +20·lg N (в фазе, на низах).",
                                       "SPL = S + 10·log P − 20·log d; N boxes add about +10·log N (incoherent) … +20·log N (in phase, low end).")) { v in
            let one = AudioMath.spl(sensitivity: v["s"]!, watts: v["p"]!, meters: v["d"]!)
            let n = max(1, v["n"]!)
            return [Result(LText("SPL одной колонки", "SPL of one box"), one, "dB", primary: n <= 1),
                    Result(LText("N колонок, некогерентно", "N boxes, incoherent"), one + 10 * log10(n), "dB", primary: n > 1),
                    Result(LText("N колонок, в фазе (НЧ)", "N boxes, in phase (LF)"), one + 20 * log10(n), "dB"),
                    Result(LText("Пиковый (+ запас 6 дБ на пики)", "Peak (+6 dB headroom)"), one + (n > 1 ? 10 * log10(n) : 0) + 6, "dB")]
        },
        AudioCalculator("dbVolts", title: LText("dBu · dBV · вольты", "dBu · dBV · volts"),
                        subtitle: LText("Перевод уровней сигнала", "Signal level conversion"),
                        icon: "bolt", tags: ["dbu", "dbv", "volt", "вольт", "уровень", "+4", "-10", "line level"],
                        fields: [Field("v", LText("Значение", "Value"), initial: 4, min: -200, max: 1000),
                                 Field("u", LText("Что введено", "Entered as"), options: [LText("dBu"), LText("dBV"), LText("Вольты (RMS)", "Volts (RMS)")])],
                        formula: LText("dBu = 20·lg(U / 0,775 В); dBV = 20·lg(U / 1 В); dBu = dBV + 2,2. «+4 dBu» — профессиональная линия, «−10 dBV» — бытовая.",
                                       "dBu = 20·log(V / 0.775 V); dBV = 20·log(V / 1 V); dBu = dBV + 2.2. +4 dBu is pro line level, −10 dBV consumer.")) { v in
            let x = v["v"]!
            let volts: Double
            switch Int(v["u"]!) {
            case 0: volts = AudioMath.volts(dBu: x)
            case 1: volts = pow(10, x / 20)
            default: volts = max(x, 0)
            }
            return [Result(LText("Вольты RMS", "Volts RMS"), volts, "V", digits: 4, primary: true),
                    Result(LText("dBu"), AudioMath.dBu(volts: volts), "dBu", digits: 2),
                    Result(LText("dBV"), AudioMath.dBV(volts: volts), "dBV", digits: 2),
                    Result(LText("Пик (синус)", "Peak (sine)"), volts * 2.squareRoot(), "V", digits: 4),
                    Result(LText("Размах (синус)", "Peak-to-peak (sine)"), volts * 2 * 2.squareRoot(), "V", digits: 4)]
        },
        AudioCalculator("dbRatio", title: LText("Децибелы ↔ разы", "Decibels ↔ ratio"),
                        subtitle: LText("По напряжению и по мощности", "Voltage and power"),
                        icon: "plusminus", tags: ["db", "дб", "ratio", "раз", "gain", "усиление"],
                        fields: [Field("db", LText("Децибелы", "Decibels"), unit: "dB", initial: 6, min: -200, max: 200)],
                        formula: LText("По напряжению: 10^(дБ/20); по мощности: 10^(дБ/10). +6 дБ ≈ 2× напряжения, +3 дБ ≈ 2× мощности, +10 дБ ≈ «вдвое громче» на слух.",
                                       "Voltage: 10^(dB/20); power: 10^(dB/10). +6 dB ≈ 2× voltage, +3 dB ≈ 2× power, +10 dB ≈ twice as loud.")) { v in
            let db = v["db"]!
            return [Result(LText("Напряжение, раз", "Voltage ratio"), pow(10, db / 20), "×", digits: 3, primary: true),
                    Result(LText("Мощность, раз", "Power ratio"), pow(10, db / 10), "×", digits: 3),
                    Result(LText("Громкость на слух, раз", "Perceived loudness"), pow(2, db / 10), "×", digits: 2)]
        },
        AudioCalculator("sumLevels", title: LText("Сложение уровней", "Adding levels"),
                        subtitle: LText("Несколько некоррелированных источников", "Several uncorrelated sources"),
                        icon: "sum", tags: ["sum", "сумма", "сложение", "db", "шум"],
                        fields: [Field("a", LText("Источник 1", "Source 1"), unit: "dB", initial: 90, min: -200, max: 200),
                                 Field("b", LText("Источник 2", "Source 2"), unit: "dB", initial: 90, min: -200, max: 200),
                                 Field("c", LText("Источник 3 (0 — нет)", "Source 3 (0 — none)"), unit: "dB", initial: 0, min: -200, max: 200),
                                 Field("d", LText("Источник 4 (0 — нет)", "Source 4 (0 — none)"), unit: "dB", initial: 0, min: -200, max: 200)],
                        formula: LText("L = 10·lg Σ 10^(Lᵢ/10). Два одинаковых источника дают +3 дБ, а не вдвое больше децибел.",
                                       "L = 10·log Σ 10^(Lᵢ/10). Two equal sources give +3 dB, not double the decibels.")) { v in
            let l = ["a", "b", "c", "d"].compactMap { v[$0] }.filter { $0 != 0 }
            return [Result(LText("Сумма", "Total"), l.isEmpty ? -.infinity : AudioMath.sum(dB: l), "dB", primary: true)]
        },
        AudioCalculator("ampPower", title: LText("Мощность, напряжение, ток", "Power, voltage, current"),
                        subtitle: LText("Выход усилителя на нагрузку", "Amplifier output into a load"),
                        icon: "bolt.horizontal", tags: ["ohm", "ом", "watt", "ватт", "amp", "усилитель", "ток", "закон ома"],
                        fields: [Field("x", LText("Значение", "Value"), initial: 1000, min: 0, max: 1e6),
                                 Field("k", LText("Что введено", "Entered as"), options: [LText("Мощность, Вт", "Power, W"), LText("Напряжение RMS, В", "Voltage RMS, V")]),
                                 Field("z", LText("Нагрузка", "Load"), unit: "Ω", initial: 8, min: 0.5, max: 10_000)],
                        formula: LText("P = U²/R, U = √(P·R), I = U/R.", "P = V²/R, V = √(P·R), I = V/R.")) { v in
            let z = v["z"]!
            let p = v["k"]! >= 1 ? v["x"]! * v["x"]! / z : v["x"]!
            let u = (p * z).squareRoot()
            return [Result(LText("Мощность", "Power"), p, "W", primary: true),
                    Result(LText("Напряжение RMS", "Voltage RMS"), u, "V", digits: 2),
                    Result(LText("Ток RMS", "Current RMS"), u / z, "A", digits: 2),
                    Result(LText("Пиковое напряжение", "Peak voltage"), u * 2.squareRoot(), "V", digits: 1)]
        },
        AudioCalculator("impedance", title: LText("Сопротивление колонок", "Loudspeaker impedance"),
                        subtitle: LText("Последовательно и параллельно", "Series and parallel"),
                        icon: "point.3.connected.trianglepath.dotted", tags: ["impedance", "импеданс", "ом", "parallel", "параллельно", "series", "последовательно"],
                        fields: [Field("a", LText("Колонка 1", "Box 1"), unit: "Ω", initial: 8, max: 1000),
                                 Field("b", LText("Колонка 2", "Box 2"), unit: "Ω", initial: 8, max: 1000),
                                 Field("c", LText("Колонка 3 (0 — нет)", "Box 3 (0 — none)"), unit: "Ω", initial: 0, max: 1000),
                                 Field("d", LText("Колонка 4 (0 — нет)", "Box 4 (0 — none)"), unit: "Ω", initial: 0, max: 1000),
                                 Field("w", LText("Соединение", "Wiring"), options: [LText("Параллельно", "Parallel"), LText("Последовательно", "Series")])],
                        formula: LText("Параллельно: 1/Z = Σ 1/Zᵢ; последовательно: Z = Σ Zᵢ. Не опускайтесь ниже минимальной нагрузки усилителя (обычно 2–4 Ом).",
                                       "Parallel: 1/Z = Σ 1/Zᵢ; series: Z = Σ Zᵢ. Stay above the amplifier's minimum load (usually 2–4 Ω).")) { v in
            let z = AudioMath.impedance(["a", "b", "c", "d"].map { v[$0]! }, parallel: v["w"]! < 1)
            return [Result(LText("Общее сопротивление", "Total impedance"), z, "Ω", digits: 2, primary: true)]
        },
        AudioCalculator("cable", title: LText("Потери в акустическом кабеле", "Speaker cable loss"),
                        subtitle: LText("Сечение, длина, демпинг-фактор", "Gauge, length, damping factor"),
                        icon: "cable.coaxial", tags: ["cable", "кабель", "сечение", "awg", "damping", "демпинг", "потери", "mm2"],
                        fields: [Field("l", LText("Длина кабеля (в одну сторону)", "Cable length (one way)"), unit: "m", initial: 30, min: 0.1, max: 5000),
                                 Field("s", LText("Сечение жилы", "Conductor cross-section"), unit: "mm²", initial: 2.5, min: 0.05, max: 100),
                                 Field("z", LText("Нагрузка", "Load"), unit: "Ω", initial: 4, min: 0.5, max: 1000),
                                 Field("df", LText("Демпинг-фактор усилителя", "Amplifier damping factor"), initial: 500, min: 1, max: 100_000)],
                        formula: LText("R = 2·l·0,0175/S (медь); потери = 20·lg(Z/(Z+R)); DF = Z/(Z/DFус + R). Хорошо: потери < 0,5 дБ, DF > 20.",
                                       "R = 2·l·0.0175/S (copper); loss = 20·log(Z/(Z+R)); DF = Z/(Z/DFamp + R). Good: loss < 0.5 dB, DF > 20.")) { v in
            let r = AudioMath.cableResistance(meters: v["l"]!, squareMillimetres: v["s"]!)
            let z = v["z"]!
            let loss = AudioMath.cableLoss(load: z, cable: r)
            return [Result(LText("Потери уровня", "Level loss"), loss, "dB", digits: 2, primary: true),
                    Result(LText("Сопротивление кабеля", "Cable resistance"), r, "Ω", digits: 3),
                    Result(LText("Теряется мощности", "Power lost"), (1 - pow(10, loss / 10)) * 100, "%"),
                    Result(LText("Демпинг-фактор у колонки", "Damping factor at the box"), AudioMath.dampingFactor(load: z, cable: r, amplifierDF: v["df"]!), digits: 0)]
        },
        AudioCalculator("line100v", title: LText("Трансляционная линия 70/100 В", "70/100 V line"),
                        subtitle: LText("Мощность и нагрузка трансляции", "Distributed system power and load"),
                        icon: "speaker.wave.2.bubble", tags: ["100v", "70v", "трансляция", "line", "трансформатор", "public address"],
                        fields: [Field("n", LText("Громкоговорителей", "Loudspeakers"), initial: 20, min: 1, max: 10_000),
                                 Field("p", LText("Отвод на каждом", "Tap per speaker"), unit: "W", initial: 6, min: 0.1, max: 1000),
                                 Field("u", LText("Линия", "Line"), options: [LText("100 В", "100 V"), LText("70 В", "70 V")])],
                        formula: LText("Z = U²/P; усилитель берут с запасом 20–25 % к сумме отводов.",
                                       "Z = V²/P; choose an amplifier 20–25 % above the sum of taps.")) { v in
            let p = v["n"]! * v["p"]!
            let u = v["u"]! >= 1 ? 70.7 : 100
            return [Result(LText("Сумма отводов", "Total taps"), p, "W", primary: true),
                    Result(LText("Усилитель (с запасом 25 %)", "Amplifier (25 % headroom)"), p * 1.25, "W", digits: 0),
                    Result(LText("Сопротивление линии", "Line impedance"), u * u / p, "Ω", digits: 2)]
        },
        AudioCalculator("cardioidSub", title: LText("Кардиоидный сабвуфер", "Cardioid subwoofer"),
                        subtitle: LText("End-fire и задний сабвуфер (gradient)", "End-fire and reversed (gradient) sub"),
                        icon: "dot.radiowaves.forward", tags: ["cardioid", "кардиоид", "sub", "саб", "end-fire", "gradient"],
                        fields: [Field("f", LText("Целевая частота", "Target frequency"), unit: "Hz", initial: 63, min: 20, max: 200), temp],
                        formula: LText("End-fire: шаг ¼ λ, передний ряд задерживается на время прохода шага. Gradient: задний саб развёрнут, задержан на расстояние между фронтами и в обратной полярности.",
                                       "End-fire: ¼ λ spacing, the front box is delayed by the travel time over the spacing. Gradient: the rear box faces back, delayed by the distance between fronts and polarity-inverted.")) { v in
            let c = AudioMath.speedOfSound(celsius: v["t"]!)
            let q = c / v["f"]! / 4
            return [Result(LText("Шаг между рядами (¼ λ)", "Row spacing (¼ λ)"), q, "m", digits: 2, primary: true),
                    Result(LText("Задержка переднего ряда", "Front row delay"), q / c * 1000, "ms", digits: 2)]
        },
        AudioCalculator("roomModes", title: LText("Комнатные моды", "Room modes"),
                        subtitle: LText("Осевые резонансы помещения", "Axial room resonances"),
                        icon: "cube", tags: ["modes", "моды", "резонанс", "room", "комната", "standing wave", "стоячие волны"],
                        fields: [Field("l", LText("Длина", "Length"), unit: "m", initial: 12, min: 1, max: 500),
                                 Field("w", LText("Ширина", "Width"), unit: "m", initial: 8, min: 1, max: 500),
                                 Field("h", LText("Высота", "Height"), unit: "m", initial: 4, min: 1, max: 100), temp],
                        formula: LText("fₙ = n·c / (2·L) для каждого размера. Совпадающие моды разных размеров — места будущего гула.",
                                       "fₙ = n·c / (2·L) for each dimension. Coinciding modes of different dimensions are where the boom will be.")) { v in
            func list(_ key: String) -> String {
                AudioMath.axialModes(length: v[key]!, celsius: v["t"]!).map { AudioCalculator.format($0, digits: 1) }.joined(separator: " · ")
            }
            return [Result(LText("Длина, Гц", "Length, Hz"), text: list("l"), primary: true),
                    Result(LText("Ширина, Гц", "Width, Hz"), text: list("w")),
                    Result(LText("Высота, Гц", "Height, Hz"), text: list("h"))]
        },
        AudioCalculator("rt60", title: LText("Время реверберации", "Reverberation time"),
                        subtitle: LText("RT60 по Сэбину и радиус гулкости", "Sabine RT60 and critical distance"),
                        icon: "dot.radiowaves.left.and.right", tags: ["rt60", "reverb", "реверберация", "sabine", "сэбин", "critical distance", "радиус гулкости"],
                        fields: [Field("l", LText("Длина", "Length"), unit: "m", initial: 30, min: 1, max: 500),
                                 Field("w", LText("Ширина", "Width"), unit: "m", initial: 20, min: 1, max: 500),
                                 Field("h", LText("Высота", "Height"), unit: "m", initial: 10, min: 1, max: 100),
                                 Field("a", LText("Средний коэффициент поглощения", "Average absorption coefficient"), initial: 0.25, min: 0.01, max: 1),
                                 Field("q", LText("Направленность колонки Q", "Loudspeaker directivity Q"), initial: 10, min: 1, max: 100)],
                        formula: LText("RT60 = 0,161·V / (S·α); Dc = 0,057·√(Q·V / RT60). Дальше радиуса гулкости отражённого звука больше прямого.",
                                       "RT60 = 0.161·V / (S·α); Dc = 0.057·√(Q·V / RT60). Beyond the critical distance there is more reflected than direct sound.")) { v in
            let (l, w, h) = (v["l"]!, v["w"]!, v["h"]!)
            let vol = l * w * h, s = 2 * (l * w + l * h + w * h)
            let rt = AudioMath.rt60Sabine(volume: vol, surface: s, absorption: v["a"]!)
            return [Result(LText("RT60"), rt, "s", digits: 2, primary: true),
                    Result(LText("Радиус гулкости", "Critical distance"), AudioMath.criticalDistance(q: v["q"]!, volume: vol, rt60: rt), "m", digits: 1),
                    Result(LText("Объём", "Volume"), vol, "m³", digits: 0),
                    Result(LText("Площадь поверхностей", "Surface"), s, "m²", digits: 0)]
        },
        AudioCalculator("tempo", title: LText("Темп → задержка", "Tempo → delay"),
                        subtitle: LText("Время дилея эффекта под BPM", "Effect delay time for a BPM"),
                        icon: "metronome", tags: ["bpm", "tempo", "темп", "delay", "дилей", "четверть", "tap"],
                        fields: [Field("bpm", LText("Темп", "Tempo"), unit: "BPM", initial: 120, min: 20, max: 400)],
                        formula: LText("Четверть = 60000 / BPM мс; восьмая — половина; с точкой — ×1,5; триоль — ×2/3.",
                                       "Quarter = 60000 / BPM ms; eighth is half; dotted ×1.5; triplet ×2/3.")) { v in
            let q = 60_000 / v["bpm"]!
            return [Result(LText("Четверть", "Quarter"), q, "ms", primary: true),
                    Result(LText("Восьмая", "Eighth"), q / 2, "ms"),
                    Result(LText("Восьмая с точкой", "Dotted eighth"), q * 0.75, "ms"),
                    Result(LText("Восьмая триоль", "Eighth triplet"), q / 3, "ms"),
                    Result(LText("Шестнадцатая", "Sixteenth"), q / 4, "ms"),
                    Result(LText("Половинная", "Half"), q * 2, "ms"),
                    Result(LText("Целая (такт 4/4)", "Whole (4/4 bar)"), q * 4, "ms")]
        },
        AudioCalculator("samples", title: LText("Сэмплы ↔ миллисекунды", "Samples ↔ milliseconds"),
                        subtitle: LText("Задержка в сэмплах при разной частоте", "Delay in samples at a sample rate"),
                        icon: "number", tags: ["samples", "сэмплы", "latency", "латентность", "buffer", "буфер", "sample rate"],
                        fields: [Field("x", LText("Значение", "Value"), initial: 256, min: 0, max: 1e9),
                                 Field("k", LText("Что введено", "Entered as"), options: [LText("Сэмплы", "Samples"), LText("Миллисекунды", "Milliseconds")]),
                                 Field("sr", LText("Частота дискретизации", "Sample rate"), options: [LText("44,1 кГц", "44.1 kHz"), LText("48 кГц", "48 kHz"), LText("96 кГц", "96 kHz")], initial: 1)],
                        formula: LText("мс = сэмплы / fs · 1000. Буфер 256 при 48 кГц — 5,3 мс в одну сторону.",
                                       "ms = samples / fs · 1000. A 256 buffer at 48 kHz is 5.3 ms one way.")) { v in
            let fs = [44_100.0, 48_000, 96_000][min(2, max(0, Int(v["sr"]!)))]
            let x = v["x"]!
            if v["k"]! >= 1 {
                return [Result(LText("Сэмплы", "Samples"), x / 1000 * fs, digits: 0, primary: true)]
            }
            return [Result(LText("Миллисекунды", "Milliseconds"), x / fs * 1000, "ms", digits: 3, primary: true),
                    Result(LText("Расстояние звука", "Sound travel"), x / fs * AudioMath.speedOfSound(celsius: 20), "m", digits: 2)]
        },
        AudioCalculator("note", title: LText("Частота ↔ нота", "Frequency ↔ note"),
                        subtitle: LText("Ближайшая нота и отклонение в центах", "Nearest note and cents off"),
                        icon: "music.note", tags: ["note", "нота", "frequency", "частота", "cents", "центы", "a440", "тюнер"],
                        fields: [Field("f", LText("Частота", "Frequency"), unit: "Hz", initial: 440, min: 1, max: 30_000),
                                 Field("a", LText("Строй A4", "Tuning A4"), unit: "Hz", initial: 440, min: 400, max: 480)],
                        formula: LText("n = 12·log₂(f / A4); 100 центов — полутон.", "n = 12·log₂(f / A4); 100 cents per semitone.")) { v in
            let n = AudioMath.note(frequency: v["f"]!, a4: v["a"]!)
            return [Result(LText("Нота", "Note"), text: "\(n.name)\(n.octave)", primary: true),
                    Result(LText("Отклонение", "Off by"), n.cents, "cents", digits: 1)]
        },
    ]
}
