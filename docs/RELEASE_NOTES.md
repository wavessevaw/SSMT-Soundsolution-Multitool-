# SSMT 1.5.1 — обучение FOH Assist: все параметры пульта

## Русский

**Обучение FOH Assist записывает весь пульт (Mac и Windows).** Раз в секунду, только чтение, на пульте ничего не меняется:
- **все параметры каналов:** гейн и фантом, срез НЧ, полярность, задержка, гейт, компрессор, инсерт, эквалайзер,
  фейдер, mute, панорама, посылы на все шины, DCA и группы mute;
- **шины и мониторы:** фейдеры, эквалайзеры (6 полос), компрессоры; матрицы, главный выход, DCA, эффекты и их параметры;
  на X32 также aux-входы и возвраты эффектов;
- **индикаторы:** уровень каналов (пик за секунду), подавление гейта и компрессора по каждому каналу, уровни и
  подавление шин, матриц и главного выхода;
- **RTA пульта:** спектр того источника, который выбран для RTA на пульте, по третям октавы.
- Счётчик «параметров пульта» на экране записи показывает, сколько прочитано (на X32 около 7 500).
- Пульт опрашивается понемногу: первый проход за минуту, потом 25 запросов в секунду; изменения с пульта приходят
  сразу. Запись четырёхчасового шоу занимает около 20 МБ. Старые записи читаются как раньше.

**Запись на всё мероприятие.** Можно поставить на несколько часов:
- файл пишется каждую секунду и сбрасывается на диск каждые 30 с: при сбое или отключении питания теряется не больше
  30 секунд, а оборванная запись читается;
- компьютер не засыпает, пока идёт запись (Mac и Windows);
- если Wi-Fi пропал, запись продолжается, секунды без связи помечаются и не идут в обучение;
- записи лежат в «Документы/SSMT/Learning».

**Данные для обучения.** Кнопка «Собрать данные для обучения» делает из всех записей один файл `SSMT-dataset.jsonl`
в той же папке: по каждому звучащему каналу раз в 10 секунд его звук (пик и средний уровень, подавление гейта и
компрессора, RTA пульта) и все настройки канала (гейн, эквалайзер, динамика, фейдер, посылы).

## English

**SSMT 1.5.1.** FOH Assist learning now records the whole console once a second, read-only: every channel parameter
(gain and phantom, high-pass, polarity, delay, gate, compressor, insert, EQ, fader, mute, pan, every send, DCA and
mute groups), buses and monitors (faders, 6-band EQ, compressors), matrices, main outputs, DCAs, effects with their
parameters, X32 aux inputs and FX returns; per-channel gate and compressor gain reduction, output levels and gain
reduction, and the console RTA (whatever source is selected for it on the console) in third octaves. The record panel
counts the console parameters read (about 7,500 on an X32). Queries are paced: a full pass in about a minute, then 25 a
second; changes made on the console arrive at once. A four-hour show takes about 20 MB. Older recordings still read.

Recordings can run for a whole show: flushed to disk every 30 s (a crash loses at most that and a cut file still reads),
the computer does not sleep while recording, and seconds without the console are marked and left out of learning.
"Build the training dataset" turns all recordings into one `SSMT-dataset.jsonl` next to them: for every playing channel
every 10 s, its sound (peak and level, gate and compressor gain reduction, the console RTA) and every channel setting.

---

# SSMT 1.5.0 — Windows и обучение FOH Assist

## Русский

**SSMT для Windows (новое)**
- Установщик `SSMT-Setup-1.5.0.exe` для Windows 10 / 11 (64 бит). В первой версии для Windows есть FOH Assist:
  симулятор и обучение. Остальные функции появятся позже.
- Ядро то же, что на Mac: симулятор, протокол X32 / X Air и обучение работают одинаково на обеих системах.
- При первом подключении к пульту Windows спросит разрешение для сети: разрешите доступ в частных сетях.

**FOH Assist после полевого теста (Mac и Windows)**
- **Настоящий пульт подключается только на чтение.** Саундчек, страховка шоу и тест пульта на настоящем пульте
  показывают «Скоро будет доступно». В симуляторе всё работает, как раньше.
- **Новая вкладка «Обучение».** Пульт подключается по Wi-Fi и ничего на нём не меняется. Раз в секунду
  записывается состояние пульта: фейдеры, гейн, эквалайзер, динамика и уровни каналов. Запись ведётся
  на всём мероприятии, счётчик показывает «Мероприятий: N из 20».
- **Закономерности.** По записям программа считает, как вы обычно настраиваете каждый тип источника: гейн,
  фейдер, срез, эквалайзер, компрессор и как часто двигаете фейдер.
- **Локальная модель.** Небольшая языковая модель (Qwen 2.5 через Ollama, на этом компьютере) отвечает на вопросы
  по закономерностям. Установите Ollama с ollama.com и выполните `ollama pull qwen2.5:1.5b`.
- Записи лежат в папке «Документы / SSMT / Learning».

## English

**SSMT 1.5.0.** New Windows app (`SSMT-Setup-1.5.0.exe`, Windows 10 / 11, 64-bit) with FOH Assist: simulator and
learning, on the same core as the Mac app. After the field test a real console is read-only on both systems:
soundcheck, show guard and console test are "coming soon" there and keep working in the simulator. The new
Learning tab records the console once a second during an event (faders, gain, EQ, dynamics, levels) without
changing anything, counts events towards 20, finds per-source patterns and lets a small local model (Qwen 2.5
through Ollama) answer questions about them. Recordings are kept in Documents / SSMT / Learning.

---

# SSMT 1.4.0 — Справочник и профиль звукорежиссёра

## Русский

**Функция №5 — Справочник**
- **18 калькуляторов:** задержка и расстояние, длина волны, уровень на расстоянии, SPL колонки, dBu / dBV / вольты,
  децибелы, сложение уровней, мощность / напряжение / ток, импеданс, потери в кабеле и демпинг-фактор, линия 100 В,
  кардиоидный саб, комнатные моды, RT60 и радиус гулкости, темп → дилей, сэмплы ↔ мс, частота ↔ нота. Считают сразу
  при вводе, значения запоминаются, результат копируется кнопкой.
- **Распайки** с рисунком контактов: XLR, TRS, TS, Insert, mini-jack, RCA, Speakon, powerCON, RJ45 / etherCON, DMX,
  MIDI, Socapex, BNC, DI.
- **Инструкции:** гейн-стейджинг, прозвонка мониторов, лайн-чек, полярность, саб и топ, дилей-линии, EQ, компрессор,
  in-ear, радиосистемы, фон, микрофоны.
- **20 пультов** — шпаргалки со ссылками на официальные руководства; **65 терминов**.
- Поиск по всему (⌘F) на русском и английском, избранное.

**Профиль звукорежиссёра**
- Перед работой — вход в профиль на этом Mac (имя и пароль), минималистичное окно с логотипом.
- **Уровни 1–40** и ранги **Медь, Бронза, Серебро, Золото**. Опыт — за часы активной работы, щелчки и реальные
  дела в пяти функциях; уровень 40 — не меньше 500 часов и 5 000 щелчков.
- **100 скрытых ачивок** — появляются, когда вы их получаете. Бейдж в боковой панели, окно нового уровня.

**Ptch:** вылеты при удалении канала и «Новый патч» исправлены (1.3.3).

## English

**SSMT 1.4.0.** Function #5 Handbook: 18 live calculators, connector pinouts with drawings, how-to guides, cheat
sheets for 20 consoles with links to official manuals, a 65-term glossary, search in English and Russian, favourites.
Engineer profile: sign in to a local profile on this Mac before work; levels 1–40 with Copper, Bronze, Silver and Gold
ranks, XP for active hours, clicks and real work in the five functions (level 40 needs 500 hours and 5,000 clicks);
100 hidden achievements, a sidebar badge and a level-up window.

---

# SSMT 1.3.3 — Ptch без вылетов

## Русский

**Ptch**
- **Исправлены вылеты** при удалении канала, «Новый патч», открытии файла и отмене удаления (⌘Z). Таблицы каналов
  и мониторных миксов больше не используют системную таблицу macOS, из-за которой происходили вылеты.
- Выделение строк: щелчок — одна строка, ⌘-щелчок — добавить / убрать, ⇧-щелчок — диапазон; Delete удаляет
  выделенные каналы целиком (если курсор не в поле ввода).
- Инспектор сцены: поворот, размеры и шрифт предмета больше не могут записаться в чужой или удалённый предмет.

**Везде:** убраны упоминания сторонних программ; импорт шоу из другой программы удалён.

Всё из 1.3.2 (FOH Assist на настоящем пульте, Qtrl) — без изменений.

## English

**SSMT 1.3.3.** Ptch: crashes on channel delete, New patch, Open and undo fixed — the channel and monitor-mix lists no
longer use the macOS system table; row selection with click, ⌘-click and ⇧-click; Delete removes whole channels; the
stage inspector edits the selected item by id. Mentions of third-party programs removed, along with the show import.

---

# SSMT 1.3.2 — FOH Assist на настоящем пульте

## Русский

**FOH Assist — работа с настоящим пультом X32 / M32 и X Air / MR**
- **Диагностика связи** (вкладка «Тест пульта» и окно настроек): отвечает ли пульт, сколько кадров уровней каналов,
  шин и RTA приходит в секунду, сколько параметров прочитано, на скольких каналах доступен гейн.
- **Входы каналов:** по умолчанию «Локальные входы 1–32» (пульт как с завода); в настройках — «Определить по пульту»
  и стейджбокс на AES50 A / B. Ассистент не трогает гейн, если не знает, какой предусилитель питает канал.
- **Надёжный опрос по Wi-Fi:** параметры читаются небольшими порциями, потерянные ответы переспрашиваются; упавшая
  связь восстанавливается сама; подсказка про разрешение «Локальная сеть» (macOS 15).
- **Компрессор / экспандер:** режим блока динамики читается; экспандер звукорежиссёра не принимается за компрессор.
- **Страховка шоу 4 раза в секунду:** звенящий монитор прижимается за ≈0,75 с и ещё раз через 0,5 с, если звенит
  дальше; фидбэк в зале вырезается и углубляется быстрее.
- **«Оркестр»** настраивает все музыкальные инструменты: ударные, бэнд, струнные, духовые.
- **Волна фейдеров** в тесте пульта: все фейдеры волной сверху вниз, чтобы оценить плавность моторных фейдеров;
  главный выход на это время выключен.
- **Тест пульта** возвращает главный выход в прежнее состояние (раньше всегда включал).
- Подписи шкал EQ поверх кривой, понятные сообщения об ошибках подключения.

**Qtrl**
- Таймлайн группы: жёлтый курсор воспроизведения, переход по щелчку на линейке, фейд в один момент с треком.
- Настройки каждой кью — по двойному клику: «Время и петли» (волна с началом, концом, петлёй, нарастанием и
  затуханием), «Фейд» (длительность и кривая с рисунком), «Уровни», «Запуск».
- Огибающая громкости на волне трека: точки на жёлтой линии, плавная или прямая.
- Фейд-аут по умолчанию оставляет трек играть на −∞; «Остановить цель» — галочкой.
- Удаление играющей кью сразу её глушит; индикаторы выходов краснеют только при перегрузке.

**Ptch** (бывший Input list): новое название; Delete при вводе текста больше не удаляет строку (вылет).

Собрано и проверено автотестами; с живым пультом протокол не сверялся — начните с «Диагностики связи» и
«Теста пульта».

## English

**SSMT 1.3.2.** FOH Assist on a real console: connection diagnostics (console answer, meter frames per second,
parameters read, gain reachability), channel inputs local 1–32 by default (auto / AES50 A / B in settings), paced
queries with re-asks and automatic reconnect, dynamics mode read, the show guard 4 times a second, Orchestra tunes every
instrument, a fader wave in the console test, the console test restores the main output as it was. Qtrl: playback
cursor and ruler seek on group timelines, per-cue settings on double click, integrated fade envelope, fade-outs keep
the target playing at −inf, deleting a playing cue stops it, output meters red only on clipping. Ptch (formerly Input
list): new name; Delete while typing no longer removes the row (crash). Built and tested automatically; the console
protocol is not yet verified on a live console.

---

# SSMT 1.3.1 — Qtrl: таймлайн группы

## Русский

**Qtrl — таймлайн группы**
- **Курсор воспроизведения**, как в DAW: жёлтая линия точно по шкале и волне, движется плавно, показывает время;
  таймлайн прокручивается за ним.
- **Линейка:** щелчок или протяжка — воспроизведение переходит туда. Играющая группа продолжает с этого места,
  неиграющая начнёт оттуда при следующем запуске (также ⌘T). Треки стартуют с нужного места, идущий фейд
  продолжается с того уровня, где был бы.
- **Фейд в тот же момент, что и трек, теперь работает** (раньше мог пропасть); фейд для трека, файл которого ещё
  готовится, применяется при его старте.
- Перетаскивание с ⌥ сдвигает звук внутри клипа; клипы прилипают к линии воспроизведения; цвет кью на клипах;
  ⌥← / ⌥→ — пауза до ±0,1 с; ⌘= / ⌘− — масштаб.

**Qtrl — новые функции**
- Режим группы **«Первая и войти»** (Start First And Enter): GO идёт по кью внутри группы и выходит после последней.
- **Повторный запуск играющей кью:** ничего, плавно остановить, остановить, остановить сразу, начать заново, выйти
  из петли; для плейлиста — следующий трек.
- Рамка GO красная, пока действует защита от двойного GO.

**Qtrl — исправления**
- Пауза посреди фейда больше не перескакивает в его конец: фейд замирает и продолжается после паузы.
- «Пауза всего», Esc и «Стоп» без цели действуют и на кью группы, запущенную отдельно.
- Остановка группы, пока её кью ждут паузу до, больше не запускает следующую кью.
- Группа, остановленная с затуханием, полностью завершается.
- Фейд-ин группы больше не оставляет незапущенные кью «тихими» на потом.

## English

**SSMT 1.3.1.** Qtrl group timeline: a yellow playback line exactly on the ruler and waveforms, moving
smoothly and followed by the view; click or drag the ruler to play from there (a stopped group is loaded there, also
with ⌘T), tracks start part-way and fades under way continue from their current point; a fade at the same moment as
its track now fades it; ⌥-drag slips the sound inside a clip; snapping to the playback line; cue colours; ⌥← / ⌥→ and
⌘= / ⌘−. Start First And Enter groups; second trigger options (incl. playlist "plays next"); red GO border during
double-GO protection. Fixes: pause freezes fades, Pause/Stop all reach cues of a group started on their own,
stopping a waiting group no longer follows on, faded group stops end cleanly, fade-ins no longer leave cues silent.

---

# SSMT 1.3.0 — Qtrl: фейды, плейлисты, мультитрек

## Русский

**Qtrl**
- **Фейд-ин и фейд-аут.** Две кнопки на панели инструментов. Фейд-ин запускает цель из тишины и поднимает до её
  уровня (или до указанного); фейд-аут уводит в тишину и останавливает. В инспекторе — переключатель направления.
- **Относительный фейд:** «изменить на ±N дБ» от текущего уровня или «до уровня».
- **Кроссфейд в плейлисте:** следующий трек начинается раньше конца текущего с плавным переходом.
- **⌘T «Загрузить до времени»:** следующий старт выделенной аудио-кью — с указанного места.
- **Мультитрек группы:** у каждой кью своя дорожка (аудио, фейд, пауза, OSC, управляющие, заметки), раскладка по
  паузе до; таймлайн прокручивается (перетаскивание пустого места, колесо / трекпад,
  полоса прокрутки); новые группы — таймлайн.
- **Курсор GO:** после запуска кью любым способом (GO, «Воспроизвести сейчас», V) встаёт на следующую; щелчок по
  играющей кью его не сбивает.
- **Исправления после проверки 1.2.1:** кью с непригодным файлом не «зависает» и не останавливает цепочку; при
  сохранении шоу файлы с одинаковым именем и размером не подменяют друг друга, а не скопированные сохраняют полный
  путь; трек, запущенный во время подготовки файла, играет без провалов.
- **Проверка всего приложения:** колонки списка кью выровнены во всех строках; зажатый пробел — один GO; клавиши,
  нажатые в окнах выбора файла, настроек и предупреждений, не запускают кью; порты OSC без разделителя тысяч; новый
  световой пульт в OSC-устройствах начинается с пустого адреса (не 127.0.0.1).

**Настройка системы:** отчёт и графики полностью на русском (раздел, точки и итерации EQ, симуляция, сглаживание).
**Список каналов и план сцены:** колонка «Стойка» и подписи палитры больше не обрезаются.
**FOH Assist:** подписи шкал на графике EQ поверх кривой.

## English

**SSMT 1.3.0.** Qtrl: fade-in (starts the target from silence) and fade-out with
toolbar buttons; relative fades; playlist crossfades; ⌘T Load to time; the group multitrack shows every cue on its
own track and scrolls, new groups are timeline groups; every start moves the playhead to the next cue. Fixes from
the 1.2.1 audit: a cue with an unplayable file no longer hangs, show media with the same name and size are no longer
mixed up on save, playback while a file is prepared no longer drops out. Full audit: cue list columns aligned in
every row, a held Space fires one GO, keys typed in panels and alerts never start cues, OSC ports without digit
grouping, new console OSC devices start with an empty address; the setup report and graphs are fully localized;
input list and stage plan labels no longer clip; FOH Assist EQ scale labels drawn above the curve.

---

# SSMT 1.2.1 — FOH Assist: новый интерфейс

## Русский

**FOH Assist (beta) — переработанный интерфейс.**

- **Общая шапка:** режимы «Саундчек · Шоу · Тест пульта», состояние пульта, уровень в зале и профиль микса;
  настройки пульта, звуковой карты и измерительного микрофона — в отдельном окне (шестерёнка).
- **Саундчек:** каналы сгруппированы по источникам (ударные, вокал, хор, струнные…) с индикаторами уровня и
  статусом; карточка выбранного канала — входное усиление, срез НЧ, компрессор, остаток отклонения тембра,
  кривая EQ пульта поверх спектра канала, четыре полосы и история изменений канала.
- **Шоу:** состояние страховки (активные коррекции, всего за шоу, время), мониторные линии с уровнями и
  обратным отсчётом восстановления, список активных коррекций — каждую можно отменить отдельно, солисты для
  разборчивости, общий журнал ассистента и звукорежиссёра.
- **Тест пульта:** отчёт по шагам.
- **Сначала подключение.** Пока пульт не подключён, во вкладке только выбор пульта: X32 / M32 и X Air / MR ищутся
  в сети Wi-Fi, найденные пульты показываются с моделью, IP и прошивкой — кнопка
  «Подключить»; можно ввести IP вручную или выбрать симулятор. Интерфейс ассистента открывается после подключения.
- **Лампочка связи** в шапке: зелёная — пульт отвечает, красная — связи нет.

**Qtrl: аудио в шоу —.** При сохранении шоу все его аудиофайлы копируются в папку «<имя шоу> Audio»
рядом с файлом шоу и записываются относительно него — шоу переносится одной папкой. До сохранения треки играют
с исходного места. Если файл не удаётся скопировать или прочитать, показывается
настоящая причина от macOS, а не общее «Файл не найден». SSMT запрашивает доступ к папкам «Рабочий стол»,
«Документы», «Загрузки» и внешним дискам с понятным объяснением.

**Qtrl: трек играет сразу после добавления.** Воспроизведение начинается, как только подготовлены
первые ~1,5 с файла (доли секунды), остальное готовится в фоне быстрее, чем играет.

**Qtrl:** трек, добавленный перетаскиванием, сразу запускается по GO. Раньше, если файл ещё готовился к
воспроизведению, кью показывала «Файл не найден» и не играла; теперь она дожидается готовности файла (до 15 с),
а в списке пишется «Файл ещё готовится». Отсутствующий файл по-прежнему сообщается сразу.
Кнопка GO и пробел больше не «засыпают» после добавления кью: курсор GO переходит на первую добавленную кью
(и с конца списка), при удалении кью под курсором — на следующую; щелчок по кью ставит на неё курсор GO.
GO, пауза и «Стоп всё» есть и в режиме «Правка»: треки можно слушать, не переходя в режим «Шоу». Пробел больше не теряется в полях (заметки, имя, номер): щелчок в любом месте вне поля или Esc заканчивает
ввод, и пробел снова запускает GO.

**Qtrl: экран переделан, без дублей.** Сверху — GO, «Далее» с заметками, «Пауза» и «Стоп всё»
(одинаково в «Правке» и «Шоу»); под ней — панель инструментов с типами кью; в центре — список; справа — вкладки
«Списки · One-shot · Идёт»; снизу — инспектор и по кнопке таймлайн; внизу — строка состояния с «Правка / Шоу».
Переключатель «Простой / Эксперт» и повторяющиеся панели убраны.

**Qtrl: группы как локальный мультитрек.** Выделите несколько кью и нажмите «Группа» (или «Сгруппировать
выделенные» в меню) — они объединятся в группу. Файлы и кью, перетащенные на нижнюю часть строки группы, попадают
внутрь неё. У группы в инспекторе есть вкладка «Мультитрек»: каждая кью — своя дорожка, старт сдвигается
перетаскиванием, края клипа обрезают начало и конец, клипы прилипают к краям соседних (⌘ при перетаскивании —
без прилипания), кнопка «Добавить треки»; в режиме «Таймлайн (все вместе)» группа играет как мультитрек.

**Qtrl: сочетания клавиш.** Пробел — GO, Esc — стоп всё, [ и ] — пауза и продолжение всего, P/S/L/V — пауза,
стоп, загрузка и прослушивание выделенных, ↑/↓ и ⇧⌘↑/⇧⌘↓ — переходы, ⌘J — к кью по номеру, ⌘]/⌘[ — «Шоу»/«Правка»,
⌘I/⌘L — инспектор и боковая панель, ⌘1/⌘0/⌘7/⌘8 — новые кью, N/Q/E/D/W/C/T — поля кью, ⌘R, ⌘D, ⌘C/⌘X/⌘V/⌘A, ⌫.
Буквенные клавиши работают и в русской раскладке. Полный список — кнопка с клавиатурой в строке состояния.

Функции №1 и №2 — без изменений.

## English

**FOH Assist (beta) — redesigned interface.** A common header with the mode switch and console / hall level /
profile status, settings in a sheet; soundcheck as a grouped channel list with live meters plus a detail card
with the EQ curve over the channel spectrum; show mode with the guard status, monitor lines with levels and a
restore countdown, active corrections that can be cancelled one by one, and one log for the assistant and the
engineer; the console test report as steps. Until a console is connected the tab shows only the console choice: X32 / M32
and X Air / MR consoles are found on the Wi-Fi network (model, IP, firmware, Connect), or enter an IP, or use the
simulator. A link lamp in the header is green while the console answers and red when the link is lost.

**Qtrl: show audio.** Saving a show copies all its audio into "<show name> Audio" next to the show file
(stored relative to it), so a show travels as one folder; before saving, tracks play from where they are. A file that cannot be copied or read
shows the system's reason instead of a generic "File not found". Folder access prompts now explain why.

**Qtrl: a track plays right after it is added** — playback starts once the first ~1.5 s are decoded
(a fraction of a second); the rest is decoded in the background faster than it plays.

**Qtrl fix:** a track dropped into the cue list now plays on GO: if its file is still being prepared, the cue waits
for it (up to 15 s) instead of reporting "File not found"; a genuinely missing file is still reported at once. GO and Space no longer stay disabled after adding cues: the
playhead moves to the first added cue (also from the end of the list) and off a deleted cue; clicking a cue puts the
playhead on it. Edit mode now has a transport (GO, pause, Stop all), so tracks can be played while
building the show; a click anywhere outside a text field (notes, name, number) or Esc ends typing, so Space is GO again. **Qtrl laid out anew, without duplicates:** GO, standing by with notes, Pause all and Stop all on top (same in Edit
and Show); the cue toolbar; the cue list; a sidebar with Cue lists · One-shot · Active; the inspector and optional
timeline at the bottom; a status bar with Edit / Show. The Simple / Expert switch and repeated panels are gone.

**Qtrl groups as a local multitrack:** select cues and press Group (or "Group the selected cues") to wrap
them; files and cues dropped on the lower part of a group row go into it; the group inspector has a Multitrack tab —
one track per cue, drag to move its start (pre-wait), drag its edges to trim, clips snap to each other (⌘ while
dragging: no snapping), "Add tracks"; in "Timeline (all together)" mode the group plays as a multitrack.

**Qtrl: keyboard shortcuts** — Space GO, Esc stop all, [ ] pause / resume all, P S L V on the selected cues,
arrows and ⇧⌘ arrows, ⌘J jump, ⌘] / ⌘[ Show / Edit, ⌘I / ⌘L panels, ⌘1 ⌘0 ⌘7 ⌘8 new cues, N Q E D W C T fields,
⌘R ⌘D ⌘C ⌘X ⌘V ⌘A ⌫. Letter keys work on any layout; the full list is behind the keyboard button in the status bar.

---

# SSMT 1.2.0 — Qtrl, Show Control Center · FOH Assist (beta)

## Русский

**Новое: функция №3 — Qtrl, Show Control Center.** Третий раздел в боковой панели.

- **Шоу из кью:** аудио, фейд, группа (все вместе, по очереди, плейлист, случайная), пауза, заметка, OSC и
  управляющие кью (старт, стоп, пауза, загрузка, сброс, перейти, сменить цель, включить/выключить, выход
  из петли). Пауза до и после, «затем»: ждать GO / следующая после паузы / следующая по окончании.
- **Два вида:** «Простой» (список и одна панель сбоку) и «Эксперт» (библиотека, кнопки one-shot на F1–F12,
  широкий мультитрековый таймлайн). Режимы «Правка» и «Шоу» (правка заблокирована).
- **Звук:** старты точны до сэмпла; любые форматы, которые читает macOS, включая звук из видеофайлов;
  файлы раскладываются в кэш на диске и читаются заранее — память не забивается, GO не ждёт диск.
  Редактор волны: начало, конец, нарастание, затухание, петля внутри трека, прослушивание с любого места.
  До 64 выходов с матрицей «канал файла → выход».
- **OSC:** мастер подключения Resolume, ETC Eos, grandMA3, ChamSys MagicQ, Behringer X32 / Midas M32
  с подсказками, проверкой связи и предупреждением о другой сети; готовые команды и OSC-монитор.
- **Надёжность:** «Стоп всё» (Esc) — плавно, повторно — мгновенно; защита от двойного GO; проверка шоу
  (пропавшие и неготовые файлы, цели, номера, клавиши); поиск пропавших файлов; выход сам восстанавливается
  после сбоя карты; Mac не засыпает, пока открыт Qtrl; выбор аудиобуфера.

**Новое (beta): функция №4 — FOH Assist.** Четвёртый раздел в боковой панели.

- **Подключение по сети:** Behringer X32 / Midas M32 и X Air / MR по сети через роутер (Wi-Fi или
  кабель); уровни и RTA пульта — по сети, звуковой кабель не нужен. Карта USB/Dante — по желанию.
- **Измерительный микрофон** — любой из библиотеки функции №1, с его калибровкой.
- **Саундчек:** канал настраивается сам каждые 2 с (гейн, срез НЧ, 4 полосы EQ, компрессор) до «Готово»;
  «Оркестр» и «Хор» одной кнопкой или диапазон каналов; баланс и подъём с проверкой фидбэка; характеры
  Мюзикл / Рок / Классика / Речь; автоматическая проверка полярности пар микрофонов; откат всех изменений.
- **Шоу (страховка):** микс ведёт звукорежиссёр; ассистент не трогает фейдеры каналов — вырезает фидбэк,
  прижимает зазвеневший монитор и возвращает, держит солиста разборчивым в массовых сценах, убирает бубнение.
- **Тест пульта** и **симуляция шоу:** проверка всей работы с пультом на выдуманном шоу с чтением значений обратно.
- **Beta:** адреса и форматы протокола X32 взяты из открытого описания и ещё не сверены с живым пультом —
  начните с «Теста пульта». WING, Yamaha, Allen & Heath — позже.

Функции №1 и №2 — без изменений.

## English

**New: function #3 — Qtrl, Show Control Center.** Cue-based show playback: audio, fade, group, wait,
memo, OSC and control cues; pre/post-wait and continue modes; Simple and Expert views (one-shot pads
on F1–F12, wide multitrack timeline); sample-accurate starts; any format macOS reads, including the
sound of video files, cached on disk and read ahead; waveform editor with an inner loop; up to 64
outputs; OSC with guided setup for Resolume, ETC Eos, grandMA3, MagicQ, X32/M32; two-stage
Stop all, double-GO guard, pre-show check, automatic output recovery, no sleep while Qtrl is open.


**New (beta): function #4 — FOH Assist.** Connects to Behringer X32 / Midas M32 and X Air / MR over the network
(levels and RTA over Wi-Fi; USB/Dante optional), measures with any microphone of the setup
library, tunes channels by itself (gain, high-pass, EQ, compressor) and groups with one button (orchestra,
choir, a channel range) with a feedback-checked ring-out, checks mic polarity automatically, and in Show mode
guards the engineer's mix (feedback notches, monitor loops, lead intelligibility in mass scenes) without moving
channel faders. Console test and show simulation exercise the whole cycle on the console with read-back.
Beta: the X32 protocol details come from public documentation and are not yet verified on a live console.

---

# Установка SSMT · Installing SSMT

## Русский

1. Скачайте `SSMT-<версия>.pkg` со страницы **Releases** репозитория.
2. Откройте файл. macOS предупредит, что разработчик не подтверждён: приложение распространяется
   бесплатно, без платной подписи Apple Developer ID.
   - **macOS 15 и новее:** нажмите «Готово», затем **Системные настройки → Конфиденциальность и безопасность**
     → внизу «SSMT-….pkg заблокирован» → **«Всё равно открыть»** → подтвердите паролем.
   - **macOS 13–14:** правый клик по файлу → **«Открыть»** → «Открыть».
3. Пройдите установщик — SSMT появится в «Программах».
4. При первом запуске SSMT может снова спросить подтверждение (как в п. 2) — это нормально.
5. При первом запуске измерения разрешите **доступ к микрофону**. Если отказали: Системные настройки →
   Конфиденциальность и безопасность → Микрофон → включите SSMT.

Требования: macOS 13 Ventura или новее, Mac на Apple Silicon или Intel, звуковая карта с входом для
измерительного микрофона (фантомное питание) и выходом в тракт системы.

После обновления версии macOS может заново спросить разрешение на микрофон — это следствие подписи без
Developer ID.

## English

1. Download `SSMT-<version>.pkg` from the repository **Releases** page.
2. Open it. macOS warns that the developer cannot be verified: SSMT is distributed for free, without a paid
   Apple Developer ID signature.
   - **macOS 15+:** click Done, then **System Settings → Privacy & Security** → "SSMT-….pkg was blocked"
     → **Open Anyway** → confirm.
   - **macOS 13–14:** right-click the file → **Open** → Open.
3. Complete the installer; SSMT is placed in Applications.
4. The first launch of SSMT may ask for the same confirmation.
5. Allow **microphone access** when asked (System Settings → Privacy & Security → Microphone).

Requirements: macOS 13 Ventura or later, Apple Silicon or Intel Mac, an audio interface with a measurement
microphone input (phantom power) and an output into the sound system.
