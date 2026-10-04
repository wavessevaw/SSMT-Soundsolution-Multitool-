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

**Qtrl: аудио в шоу — как в QLab.** При сохранении шоу все его аудиофайлы копируются в папку «<имя шоу> Audio»
рядом с файлом шоу и записываются относительно него — шоу переносится одной папкой. До сохранения треки играют
с исходного места. Если файл не удаётся скопировать или прочитать, показывается
настоящая причина от macOS, а не общее «Файл не найден». SSMT запрашивает доступ к папкам «Рабочий стол»,
«Документы», «Загрузки» и внешним дискам с понятным объяснением.

**Qtrl: трек играет сразу после добавления, как в QLab.** Воспроизведение начинается, как только подготовлены
первые ~1,5 с файла (доли секунды), остальное готовится в фоне быстрее, чем играет.

**Qtrl:** трек, добавленный перетаскиванием, сразу запускается по GO. Раньше, если файл ещё готовился к
воспроизведению, кью показывала «Файл не найден» и не играла; теперь она дожидается готовности файла (до 15 с),
а в списке пишется «Файл ещё готовится». Отсутствующий файл по-прежнему сообщается сразу.
Кнопка GO и пробел больше не «засыпают» после добавления кью: курсор GO переходит на первую добавленную кью
(и с конца списка), при удалении кью под курсором — на следующую; щелчок по кью ставит на неё курсор GO, как в QLab.
В режиме «Правка» появилась панель воспроизведения — GO, пауза и «Стоп всё»: треки можно слушать, не переходя
в режим «Шоу». Пробел больше не теряется в полях (заметки, имя, номер): щелчок в любом месте вне поля или Esc заканчивает
ввод, и пробел снова запускает GO.

**Qtrl: экран переделан по образцу QLab, без дублей.** Сверху — GO, «Далее» с заметками, «Пауза» и «Стоп всё»
(одинаково в «Правке» и «Шоу»); под ней — панель инструментов с типами кью; в центре — список; справа — вкладки
«Списки · One-shot · Идёт»; снизу — инспектор и по кнопке таймлайн; внизу — строка состояния с «Правка / Шоу».
Переключатель «Простой / Эксперт» и повторяющиеся панели убраны.

**Qtrl: группы как локальный мультитрек (как в QLab).** Выделите несколько кью и нажмите «Группа» (или «Сгруппировать
выделенные» в меню) — они объединятся в группу. Файлы и кью, перетащенные на нижнюю часть строки группы, попадают
внутрь неё. У группы в инспекторе есть вкладка «Мультитрек»: каждая кью — своя дорожка, старт сдвигается
перетаскиванием, края клипа обрезают начало и конец, клипы прилипают к краям соседних (⌘ при перетаскивании —
без прилипания), кнопка «Добавить треки»; в режиме «Таймлайн (все вместе)» группа играет как мультитрек.

**Qtrl: сочетания клавиш QLab.** Пробел — GO, Esc — стоп всё, [ и ] — пауза и продолжение всего, P/S/L/V — пауза,
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

**Qtrl: show audio as in QLab.** Saving a show copies all its audio into "<show name> Audio" next to the show file
(stored relative to it), so a show travels as one folder; before saving, tracks play from where they are. A file that cannot be copied or read
shows the system's reason instead of a generic "File not found". Folder access prompts now explain why.

**Qtrl: a track plays right after it is added, as in QLab** — playback starts once the first ~1.5 s are decoded
(a fraction of a second); the rest is decoded in the background faster than it plays.

**Qtrl fix:** a track dropped into the cue list now plays on GO: if its file is still being prepared, the cue waits
for it (up to 15 s) instead of reporting "File not found"; a genuinely missing file is still reported at once. GO and Space no longer stay disabled after adding cues: the
playhead moves to the first added cue (also from the end of the list) and off a deleted cue; clicking a cue puts the
playhead on it, as in QLab. Edit mode now has a transport (GO, pause, Stop all), so tracks can be played while
building the show; a click anywhere outside a text field (notes, name, number) or Esc ends typing, so Space is GO again. **Qtrl laid out as QLab, without duplicates:** GO, standing by with notes, Pause all and Stop all on top (same in Edit
and Show); the cue toolbar; the cue list; a sidebar with Cue lists · One-shot · Active; the inspector and optional
timeline at the bottom; a status bar with Edit / Show. The Simple / Expert switch and repeated panels are gone.

**Qtrl groups as a local multitrack (as in QLab):** select cues and press Group (or "Group the selected cues") to wrap
them; files and cues dropped on the lower part of a group row go into it; the group inspector has a Multitrack tab —
one track per cue, drag to move its start (pre-wait), drag its edges to trim, clips snap to each other (⌘ while
dragging: no snapping), "Add tracks"; in "Timeline (all together)" mode the group plays as a multitrack.

**Qtrl: QLab keyboard shortcuts** — Space GO, Esc stop all, [ ] pause / resume all, P S L V on the selected cues,
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
- **OSC:** мастер подключения Resolume, ETC Eos, grandMA3, ChamSys MagicQ, Behringer X32 / Midas M32 и QLab
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
outputs; OSC with guided setup for Resolume, ETC Eos, grandMA3, MagicQ, X32/M32 and QLab; two-stage
Stop all, double-GO guard, pre-show check, automatic output recovery, no sleep while Qtrl is open.


**New (beta): function #4 — FOH Assist.** Connects to Behringer X32 / Midas M32 and X Air / MR over the network
over the network (levels and RTA over Wi-Fi; USB/Dante optional), measures with any microphone of the setup
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
