import AppKit
import SwiftUI

@main
struct SSMTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var localizer = Localizer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .ssmtEnvironment(model, localizer)
                .onAppear {
                    appDelegate.model = model
                    MiniPanelController.shared.attach(model: model, localizer: localizer)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                // ⌘O / ⌘S act on the open tab: the setup session or the input list document.
                Button(localizer.t(model.section == .show ? "show.open" : (model.section == .inputList ? "il.open" : "session.open"))) {
                    switch model.section {
                    case .show: model.show.open()
                    case .inputList: model.inputList.open()
                    case .setup, .assist, .handbook: model.openSession()
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button(localizer.t(model.section == .show ? "show.save" : (model.section == .inputList ? "il.save" : "session.save"))) {
                    switch model.section {
                    case .show: model.show.save()
                    case .inputList: model.inputList.save()
                    case .setup, .assist, .handbook: model.saveSession()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                if model.section == .show {
                    Button(localizer.t("il.saveAs")) { model.show.save(as: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button(localizer.t("show.new")) { model.show.newDocument() }
                    Button(localizer.t("show.addAudio")) { model.show.chooseAudioFiles() }
                        .keyboardShortcut("1", modifiers: [.command])
                }
                if model.section == .inputList {
                    Button(localizer.t("il.saveAs")) { model.inputList.save(as: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button(localizer.t("il.new")) { model.inputList.newDocument() }
                    Button(localizer.t("il.export.pdf")) { InputListExporter.export(.pdf, store: model.inputList, loc: localizer) }
                        .keyboardShortcut("e", modifiers: [.command])
                }
                Divider()
                Button(localizer.t("report.pdf")) { model.exportReport(pdf: true, localizer: localizer) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(localizer.t("report.png")) { model.exportReport(pdf: false, localizer: localizer) }
                Button(localizer.t("report.copy")) { model.copyReportText() }
            }
            CommandMenu("SSMT") {
                Button(localizer.t("action.stop")) { model.emergencyStop() }
                    .keyboardShortcut(.escape, modifiers: [])
                // System setup only: in Qtrl these keys belong to the cue list (⌘1 audio, ⌘L sidebar, ⌘D duplicate…).
                if model.section == .setup {
                    Button(localizer.t("noise.toggle")) { model.toggleNoise() }
                        .keyboardShortcut("n", modifiers: [.command])
                    Button(localizer.t("delay.find")) { model.findDelay() }
                        .keyboardShortcut("d", modifiers: [.command])
                    Divider()
                    Button(localizer.t("mode.wizard")) { model.appMode = .wizard }
                        .keyboardShortcut("1", modifiers: [.command])
                    Button(localizer.t("mode.expert")) { model.appMode = .expert }
                        .keyboardShortcut("e", modifiers: [.command])
                    Button(localizer.t("mode.stage")) { model.stageMode.toggle() }
                        .keyboardShortcut("l", modifiers: [.command])
                    Divider()
                    Button(localizer.t("wizard.begin")) { model.wizardStart() }
                        .keyboardShortcut("b", modifiers: [.command])
                    Divider()
                }
                Button(localizer.t("mini.toggle")) { MiniPanelController.shared.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button(localizer.t("mini.clickThroughOff")) { MiniPanelController.shared.clickThrough = false }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Black from the very first frame: no white flash before SwiftUI draws.
        for w in NSApp.windows { w.backgroundColor = .black }
        // Esc = STOP everywhere in the app, even while a text field or picker has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.model?.emergencyStop() }
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopEngine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
