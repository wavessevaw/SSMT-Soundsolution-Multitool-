import Foundation

public enum AchievementRarity: Int, Codable, CaseIterable, Sendable {
    case common, rare, epic, legendary

    public var xp: Int { [50, 100, 250, 500][rawValue] }

    public var name: LText {
        switch self {
        case .common: return LText("Обычная", "Common")
        case .rare: return LText("Редкая", "Rare")
        case .epic: return LText("Эпическая", "Epic")
        case .legendary: return LText("Легендарная", "Legendary")
        }
    }
}

public enum AchievementCategory: String, CaseIterable, Sendable {
    case general, time, setup, ptch, qtrl, foh, handbook, levels, secrets

    public var name: LText {
        switch self {
        case .general: return LText("Общие", "General")
        case .time: return LText("Время", "Time")
        case .setup: return LText("Настройка системы", "System setup")
        case .ptch: return LText("Ptch")
        case .qtrl: return LText("Qtrl")
        case .foh: return LText("FOH Assist")
        case .handbook: return LText("Справочник", "Handbook")
        case .levels: return LText("Уровни", "Levels")
        case .secrets: return LText("Секреты", "Secrets")
        }
    }
}

/// What unlocks an achievement, read from the recorded progress.
public enum AchievementCondition: Sendable {
    /// Counter reached the value (counters also keep maxima, see `PlayerProgress.recordMax`).
    case count(String, Int)
    /// Number of distinct items in a set.
    case distinct(String, Int)
    case hours(Double)
    case clicks(Int)
    case level(Int)
    /// Number of other achievements unlocked.
    case collected(Int)
}

public struct Achievement: Identifiable, Sendable {
    public var id: String
    public var category: AchievementCategory
    public var title: LText
    public var text: LText
    public var rarity: AchievementRarity
    public var condition: AchievementCondition
    /// Shown on the hidden card ("Hint: pink noise"); nil — no hint.
    public var hint: LText?

    /// Target for a progress bar (counters with a threshold above one).
    public var target: (key: String, value: Double, isSet: Bool)? {
        switch condition {
        case .count(let k, let n) where n > 1: return (k, Double(n), false)
        case .distinct(let k, let n) where n > 1: return (k, Double(n), true)
        default: return nil
        }
    }
}

extension Achievement {
    // Short builder for the catalog.
    fileprivate init(_ id: String, _ cat: AchievementCategory, _ ru: String, _ en: String, _ textRu: String, _ textEn: String,
                     _ rarity: AchievementRarity, _ condition: AchievementCondition, hint: (String, String)? = nil) {
        self.id = id
        category = cat
        title = LText(ru, en)
        text = LText(textRu, textEn)
        self.rarity = rarity
        self.condition = condition
        self.hint = hint.map { LText($0.0, $0.1) }
    }
}

public enum AchievementCatalog {
    static let consoleCount = Handbook.articles(in: .consoles).filter { $0.id != "consoleCommon" }.count
    static let termCount = Handbook.articles(in: .glossary).count

    public static func achievement(_ id: String) -> Achievement? { all.first { $0.id == id } }

    public static let all: [Achievement] = [
        // General
        Achievement("firstSound", .general, "Первый звук", "First sound", "Первый запуск после создания профиля.", "First launch with a new profile.", .common, .count("app.launch", 1)),
        Achievement("justLooking", .general, "Я только посмотреть", "Just looking", "Открыть программу и закрыть меньше чем через 10 секунд.", "Open the app and quit within 10 seconds.", .common, .count("app.quickQuit", 1)),
        Achievement("tourist", .general, "Турист", "Tourist", "Заглянуть во все пять функций.", "Visit all five functions.", .common, .distinct("sections", 5), hint: ("все функции", "every function")),
        Achievement("fullSet", .general, "Полный комплект", "Full set", "Поработать во всех пяти функциях за одну сессию.", "Use all five functions in one session.", .rare, .count("session.allSections", 1)),
        Achievement("polyglot", .general, "Смена языка", "Polyglot", "Переключить язык интерфейса. Hello, world.", "Switch the interface language. Привет, мир.", .common, .count("ui.language", 1)),
        Achievement("undoAddict", .general, "Ctrl+Z-зависимый", "Undo addict", "Отменить действие 100 раз. Ничего, бывает.", "Undo 100 times. It happens.", .rare, .count("key.undo", 100), hint: ("⌘Z", "⌘Z")),
        Achievement("saveOften", .general, "Сохраняйся чаще", "Save often", "Сохранить документ 50 раз через ⌘S.", "Save 50 times with ⌘S.", .common, .count("key.save", 50)),
        Achievement("pianist", .general, "Пианист", "Pianist", "200 действий горячими клавишами.", "200 keyboard shortcuts.", .rare, .count("key.shortcut", 200)),
        Achievement("woodpecker", .general, "Дятел", "Woodpecker", "10 щелчков в одно место за 3 секунды.", "10 clicks on one spot within 3 seconds.", .common, .count("input.woodpecker", 1)),
        Achievement("catOnKeyboard", .general, "Кот прошёлся по клавиатуре", "Cat on the keyboard", "15 нажатий клавиш за одну секунду.", "15 key presses in one second.", .rare, .count("input.cat", 1)),
        Achievement("clickMania", .general, "Кликер-маньяк", "Click mania", "50 щелчков за минуту.", "50 clicks in a minute.", .common, .count("input.burst", 1)),
        Achievement("thousandClicks", .general, "Тысяча щелчков", "A thousand clicks", "Тысячный щелчок в программе.", "Your thousandth click.", .common, .clicks(1_000)),
        Achievement("ironFinger", .general, "Палец железный", "Iron finger", "10 000 щелчков.", "10,000 clicks.", .epic, .clicks(10_000)),
        // Time
        Achievement("nightOwl", .time, "Сова у пульта", "Night owl", "Работать после трёх ночи.", "Work after 3 a.m.", .rare, .count("time.night", 1), hint: ("ночь", "night")),
        Achievement("earlyBird", .time, "Жаворонок-монтировщик", "Early bird", "Запустить программу с пяти до шести утра.", "Launch the app between 5 and 6 a.m.", .rare, .count("app.earlyLaunch", 1), hint: ("утро", "morning")),
        Achievement("longSoundcheck", .time, "Саундчек затянулся", "Long soundcheck", "Четыре часа работы без перерыва.", "Four hours without a break.", .rare, .count("time.maxContinuousMin", 240)),
        Achievement("liveHere", .time, "Живу здесь", "I live here", "12 часов работы за одни сутки.", "12 hours of work in one day.", .epic, .count("time.maxDayMin", 720)),
        Achievement("noWeekends", .time, "Без выходных", "No weekends", "Семь дней подряд с программой.", "Seven days in a row.", .rare, .count("time.maxStreak", 7)),
        Achievement("season", .time, "Сезон", "Season", "Работа в 30 разных днях.", "Work on 30 different days.", .epic, .count("time.days", 30)),
        Achievement("comeback", .time, "Вернулся", "Comeback", "Запустить программу после месяца перерыва.", "Return after a month away.", .common, .count("app.returned", 1)),
        Achievement("fridayRider", .time, "Пятница, вечер, райдер", "Friday night rider", "Править инпут-лист в пятницу после 18:00.", "Edit an input list on Friday after 6 p.m.", .common, .count("ptch.fridayEvening", 1), hint: ("пятница", "Friday")),
        Achievement("newYear", .time, "Новогодний корпоратив", "New Year's gig", "Работать 31 декабря.", "Work on December 31.", .rare, .count("time.dec31", 1), hint: ("31 декабря", "December 31")),
        Achievement("aprilFool", .time, "Это не шутка", "No joke", "Открыть программу 1 апреля.", "Open the app on April 1.", .common, .count("app.april1", 1)),
        Achievement("hundredHours", .time, "Сотка", "A hundred", "100 часов в программе.", "100 hours in the app.", .rare, .hours(100)),
        Achievement("veteran", .time, "Ветеран", "Veteran", "300 часов в программе.", "300 hours in the app.", .epic, .hours(300)),
        // System setup
        Achievement("pinkNoise", .setup, "Розовый шум в голове", "Pink noise on the brain", "Суммарно час розового шума.", "One hour of pink noise in total.", .common, .count("setup.noiseSeconds", 3_600), hint: ("розовый шум", "pink noise")),
        Achievement("firstDelay", .setup, "Первая задержка", "First delay", "Найти задержку системы.", "Find the system delay.", .common, .count("setup.delayFound", 1)),
        Achievement("synchro", .setup, "Синхронисты", "Synchronised", "Согласовать саб и топ.", "Align sub and top.", .common, .count("setup.aligned", 1)),
        Achievement("polarityPolitics", .setup, "Полярность — не политика", "Polarity is not politics", "Исправить перевёрнутую полярность.", "Fix an inverted polarity.", .rare, .count("setup.polarityFixed", 1)),
        Achievement("eqMan", .setup, "Эквалайзерщик", "EQ person", "Применить 100 полос EQ.", "Apply 100 EQ bands.", .rare, .count("setup.eqBands", 100)),
        Achievement("clientReport", .setup, "Отчёт для заказчика", "Client report", "Экспортировать отчёт.", "Export a report.", .common, .count("setup.reportExport", 1)),
        Achievement("echo", .setup, "Эхо-эхо-эхо", "Echo-echo-echo", "Измерение с когерентностью ниже 0,5. Вы точно не в бане?", "A measurement with coherence below 0.5. Are you in a sauna?", .rare, .count("setup.lowCoherence", 1)),
        Achievement("simulant", .setup, "Симулянт", "Simulant", "10 настроек в виртуальном зале до конца.", "Finish 10 setups in the virtual room.", .common, .count("setup.simFinished", 10)),
        Achievement("quietPlease", .setup, "Тихо, идёт измерение", "Quiet, please", "Нажать СТОП 20 раз.", "Press STOP 20 times.", .common, .count("setup.stop", 20)),
        Achievement("calibrated", .setup, "Калиброванный", "Calibrated", "Загрузить файл калибровки микрофона.", "Load a microphone calibration file.", .common, .count("setup.calibration", 1)),
        Achievement("siberia", .setup, "Опен-эйр в Сибири", "Open air in Siberia", "Температура воздуха в настройках ниже 5 °C.", "Air temperature set below 5 °C.", .rare, .count("setup.cold", 1)),
        Achievement("desert", .setup, "Опен-эйр в пустыне", "Open air in the desert", "Температура воздуха выше 35 °C.", "Air temperature set above 35 °C.", .rare, .count("setup.hot", 1)),
        Achievement("oneTwo", .setup, "Раз, раз, проверка", "One, two, check", "Микрофон громче −6 dBFS.", "Microphone above −6 dBFS.", .common, .count("setup.micHot", 1)),
        Achievement("allSubs", .setup, "Мастер на все сабы", "Master of all subs", "10 законченных мастеров настройки.", "Finish the setup wizard 10 times.", .epic, .count("setup.finished", 10)),
        // Ptch
        Achievement("firstRider", .ptch, "Первый райдер", "First rider", "Добавить первый канал в инпут-лист.", "Add the first channel to an input list.", .common, .count("ptch.channelAdded", 1)),
        Achievement("happyDrummer", .ptch, "Барабанщик доволен", "Happy drummer", "12 и больше каналов барабанов.", "12 or more drum channels.", .common, .count("ptch.maxDrums", 12), hint: ("барабаны", "drums")),
        Achievement("pocketOrchestra", .ptch, "Оркестр в кармане", "Pocket orchestra", "48 и больше каналов в одном патче.", "48 or more channels in one patch.", .rare, .count("ptch.maxChannels", 48), hint: ("много каналов", "many channels")),
        Achievement("sm58", .ptch, "SM58 forever", "SM58 forever", "10 каналов с SM58 в одном патче.", "10 SM58 channels in one patch.", .common, .count("ptch.maxSM58", 10)),
        Achievement("phantomPain", .ptch, "Фантомные боли", "Phantom pain", "+48 В на 24 каналах.", "+48 V on 24 channels.", .common, .count("ptch.maxPhantom", 24)),
        Achievement("emptyRider", .ptch, "Пустой райдер", "Empty rider", "Экспортировать инпут-лист без единого канала.", "Export an input list with no channels.", .rare, .count("ptch.emptyExport", 1)),
        Achievement("stageDesigner", .ptch, "Дизайнер сцены", "Stage designer", "20 предметов на плане сцены.", "20 items on the stage plan.", .common, .count("ptch.maxStageItems", 20)),
        Achievement("whereIsMyWedge", .ptch, "Где мой монитор?", "Where's my wedge?", "10 мониторных миксов.", "10 monitor mixes.", .common, .count("ptch.maxMixes", 10)),
        Achievement("stageboxSommelier", .ptch, "Стейджбокс-сомелье", "Stage box sommelier", "Пронумеровать стейджбокс автоматически.", "Number the stage box automatically.", .common, .count("ptch.stagebox", 1)),
        Achievement("copyPaste", .ptch, "Копипаст", "Copy-paste", "Продублировать 50 каналов.", "Duplicate 50 channels.", .common, .count("ptch.duplicated", 50)),
        Achievement("toPrint", .ptch, "Райдер ушёл в печать", "Off to print", "10 экспортов.", "10 exports.", .rare, .count("ptch.export", 10)),
        // Qtrl
        Achievement("go", .qtrl, "GO!", "GO!", "Первый GO.", "First GO.", .common, .count("qtrl.go", 1)),
        Achievement("thousandGo", .qtrl, "Тысяча GO", "A thousand GOs", "Нажать GO тысячу раз.", "Press GO a thousand times.", .epic, .count("qtrl.go", 1_000)),
        Achievement("doubleGo", .qtrl, "Двойной GO не пройдёт", "No double GO", "Защита от двойного GO сработала.", "The double-GO guard kicked in.", .common, .count("qtrl.doubleGo", 1)),
        Achievement("panic", .qtrl, "Паника", "Panic", "«Стоп всё» во время шоу.", "Stop all during a show.", .common, .count("qtrl.panic", 1)),
        Achievement("panic2", .qtrl, "Паника ×2", "Panic ×2", "Мгновенный стоп вторым Esc.", "Instant stop with a second Esc.", .rare, .count("qtrl.panicHard", 1)),
        Achievement("endlessPlaylist", .qtrl, "Плейлист бесконечный", "Endless playlist", "Плейлист из 50 треков.", "A playlist of 50 tracks.", .rare, .count("qtrl.maxPlaylist", 50)),
        Achievement("multitracker", .qtrl, "Мультитрекер", "Multitracker", "Таймлайн группы с 16 треками.", "A timeline group with 16 tracks.", .rare, .count("qtrl.maxTimelineTracks", 16)),
        Achievement("fadeMaster", .qtrl, "Фейд-мастер", "Fade master", "100 фейдов.", "100 fades.", .rare, .count("qtrl.fade", 100)),
        Achievement("timeLoop", .qtrl, "Петля времени", "Time loop", "Трек с петлёй играл 30 минут подряд.", "A looping track played for 30 minutes.", .rare, .count("qtrl.loopMinutes", 30), hint: ("петля", "loop")),
        Achievement("lightingSoul", .qtrl, "Светорежиссёр в душе", "Lighting designer at heart", "50 OSC-команд.", "50 OSC commands.", .rare, .count("qtrl.osc", 50)),
        Achievement("cleanShow", .qtrl, "Ни одного провала", "Clean show", "30 GO за сессию без ошибок файлов.", "30 GOs in a session without file errors.", .epic, .count("qtrl.cleanShow", 1)),
        Achievement("oneShotCowboy", .qtrl, "One-shot-ковбой", "One-shot cowboy", "20 нажатий one-shot.", "20 one-shot presses.", .common, .count("qtrl.oneShot", 20)),
        Achievement("deletedPlaying", .qtrl, "Удалил играющее", "Deleted it live", "Удалить играющую кью. Смело.", "Delete a playing cue. Bold.", .common, .count("qtrl.deletePlaying", 1)),
        Achievement("intermission", .qtrl, "Антракт", "Intermission", "Пауза всего дольше 15 минут.", "Pause all for more than 15 minutes.", .common, .count("qtrl.longPause", 1), hint: ("антракт", "intermission")),
        Achievement("premiere", .qtrl, "Премьера", "Premiere", "Сохранить шоу из 100+ кью.", "Save a show with 100+ cues.", .epic, .count("qtrl.bigShow", 1)),
        // FOH Assist
        Achievement("helloConsole", .foh, "Привет, пульт", "Hello, console", "Первое подключение к пульту.", "First connection to a console.", .common, .count("foh.connect", 1)),
        Achievement("airConsole", .foh, "Пульт из воздуха", "Console out of thin air", "Подключиться к симулятору.", "Connect to the simulator.", .common, .count("foh.simulator", 1)),
        Achievement("stadiumWave", .foh, "Волна на стадионе", "Stadium wave", "Запустить волну фейдеров.", "Run the fader wave.", .common, .count("foh.wave", 1)),
        Achievement("feedbackTamed", .foh, "Фидбэк укрощён", "Feedback tamed", "Страховка вырезала заводку в зале.", "The show guard notched hall feedback.", .rare, .count("foh.feedbackCut", 1)),
        Achievement("stopRinging", .foh, "Монитор, не звени", "Stop ringing", "Ассистент прижал звенящий монитор.", "The assistant dipped a ringing wedge.", .rare, .count("foh.monitorDip", 1)),
        Achievement("choir", .foh, "Хор имени SSMT", "The SSMT choir", "Настроить хор одной кнопкой.", "Tune a choir with one button.", .rare, .count("foh.choir", 1), hint: ("хор", "choir")),
        Achievement("orchestra", .foh, "Оркестр одной кнопкой", "One-button orchestra", "Настроить оркестр одной кнопкой.", "Tune an orchestra with one button.", .rare, .count("foh.orchestra", 1)),
        Achievement("consoleSurvived", .foh, "Пульт выжил", "Console survived", "Тест пульта пройден целиком.", "The console test passed.", .common, .count("foh.testPassed", 1)),
        Achievement("rollback", .foh, "Откатчик", "Rollback", "Откатить все изменения ассистента.", "Revert everything the assistant did.", .common, .count("foh.revert", 1)),
        Achievement("wifiFailed", .foh, "Wi-Fi подвёл", "Wi-Fi let me down", "Связь с пультом восстановилась 10 раз.", "The console link recovered 10 times.", .rare, .count("foh.reconnect", 10)),
        Achievement("losslessShow", .foh, "Шоу без потерь", "Lossless show", "Два часа страховки шоу.", "Two hours of show guard.", .epic, .count("foh.guardSeconds", 7_200)),
        Achievement("polarBear", .foh, "Полярный медведь", "Polar bear", "Ассистент нашёл перевёрнутую пару микрофонов.", "The assistant found an inverted mic pair.", .rare, .count("foh.polarity", 1)),
        Achievement("gainGuru", .foh, "Гейн-гуру", "Gain guru", "100 изменений гейна ассистентом.", "100 gain changes by the assistant.", .rare, .count("foh.gainChanges", 100)),
        Achievement("rock", .foh, "Рок не умрёт", "Rock never dies", "Саундчек с характером «Рок».", "A soundcheck with the Rock character.", .common, .count("foh.rock", 1)),
        Achievement("classic", .foh, "Классика жанра", "A classic", "Саундчек с характером «Классика».", "A soundcheck with the Classical character.", .common, .count("foh.classic", 1)),
        // Handbook
        Achievement("bookworm", .handbook, "Книжный червь", "Bookworm", "Открыть 50 страниц справочника.", "Open 50 handbook pages.", .rare, .count("hb.pages", 50)),
        Achievement("pinTwo", .handbook, "Знаю, где пин 2", "I know where pin 2 is", "Открыть распайку XLR пять раз.", "Open the XLR pinout five times.", .common, .count("hb.xlr", 5)),
        Achievement("calculator", .handbook, "Калькуляторщик", "Number cruncher", "100 расчётов в калькуляторах.", "100 calculations.", .rare, .count("hb.calc", 100)),
        Achievement("speedOfSound", .handbook, "Скорость звука", "Speed of sound", "Посчитать задержку 20 раз.", "Calculate a delay 20 times.", .common, .count("hb.delayCalc", 20)),
        Achievement("sabine", .handbook, "Сам себе Сэбин", "Your own Sabine", "Посчитать время реверберации.", "Calculate a reverberation time.", .common, .count("hb.rt60", 1), hint: ("Сэбин", "Sabine")),
        Achievement("bookmarks", .handbook, "Закладки", "Bookmarks", "10 страниц в избранном.", "10 pages in favourites.", .common, .count("hb.maxFavorites", 10)),
        Achievement("encyclopedist", .handbook, "Энциклопедист", "Encyclopedist", "Прочитать все термины.", "Read every glossary term.", .epic, .distinct("hb.terms", termCount)),
        Achievement("consoleExpert", .handbook, "Знаток пультов", "Console connoisseur", "Открыть все пульты справочника.", "Open every console page.", .rare, .distinct("hb.consoles", consoleCount)),
        Achievement("searcher", .handbook, "Поисковик", "Searcher", "100 поисков.", "100 searches.", .common, .count("hb.search", 100)),
        Achievement("speakonBackwards", .handbook, "Спикон наоборот", "Speakon backwards", "Найти «спикон» через поиск.", "Search for \"спикон\".", .common, .count("hb.speakon", 1)),
        // Levels
        Achievement("copperForehead", .levels, "Медный лоб", "Copper forehead", "Уровень 5.", "Level 5.", .common, .level(5)),
        Achievement("bronzeAge", .levels, "Бронзовый век", "Bronze age", "Уровень 11 — ранг Бронза.", "Level 11 — Bronze rank.", .rare, .level(11)),
        Achievement("silverSound", .levels, "Серебряный звук", "Silver sound", "Уровень 21 — ранг Серебро.", "Level 21 — Silver rank.", .epic, .level(21)),
        Achievement("goldenEars", .levels, "Золотые уши", "Golden ears", "Уровень 31 — ранг Золото.", "Level 31 — Gold rank.", .epic, .level(31)),
        Achievement("fohLegend", .levels, "Легенда FOH", "FOH legend", "Уровень 40: 500 часов и 5 000 щелчков.", "Level 40: 500 hours and 5,000 clicks.", .legendary, .level(40)),
        // Secrets
        Achievement("secretRoom", .secrets, "Тайная комната", "Secret room", "Найти спрятанную игру.", "Find the hidden game.", .legendary, .count("secret.game", 1)),
        Achievement("retroGamer", .secrets, "Ретрогеймер", "Retro gamer", "Запустить спрятанную игру в эмуляторе.", "Launch the hidden game in an emulator.", .epic, .count("secret.gamePlayed", 1)),
        Achievement("perfectionist", .secrets, "Перфекционист", "Perfectionist", "Поменять одно поле калькулятора 30 раз подряд.", "Change one calculator field 30 times in a row.", .common, .count("secret.perfectionist", 1)),
        Achievement("quietGenerator", .secrets, "Тише едешь", "Slow and steady", "Шум генератора на минимуме 10 минут.", "Generator noise at minimum for 10 minutes.", .common, .count("secret.quietSeconds", 600)),
        Achievement("collector", .secrets, "Коллекционер", "Collector", "Открыть все остальные ачивки.", "Unlock every other achievement.", .legendary, .collected(99)),
    ]
}
