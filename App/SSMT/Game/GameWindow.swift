import AppKit
import SwiftUI

/// The hidden game is a real Sega Mega Drive / Genesis cartridge image (built from `Game/megadrive` with SGDK).
/// SSMT ships the ROM and hands it to an emulator (OpenEmu if installed) or saves it for a flash cart.
enum GameROM {
    static let fileName = "soundcheck-of-the-dead.md"
    static let openEmuID = "org.openemu.OpenEmu"

    static var bundled: URL? { Bundle.main.url(forResource: "soundcheck", withExtension: "bin") }

    static var size: Int {
        guard let url = bundled, let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return n
    }

    static var openEmu: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: openEmuID) }

    /// A copy outside the app bundle with an extension emulators recognise (.md).
    static func exported() throws -> URL {
        guard let src = bundled else { throw CocoaError(.fileNoSuchFile) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    static func play() {
        guard let app = openEmu, let rom = try? exported() else { return }
        MainActor.assumeIsolated { ProfileCenter.shared.record("secret.gamePlayed") }
        NSWorkspace.shared.open([rom], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal() {
        guard let rom = try? exported() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([rom])
    }

    @MainActor
    static func save() {
        guard let src = bundled else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    static func screenshot(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct GameLauncherView: View {
    @EnvironmentObject var loc: Localizer
    @State private var shot = 0
    @State private var hasOpenEmu = GameROM.openEmu != nil
    static let shots = ["game-shot-title", "game-shot-play", "game-shot-boss"]
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 10) {
                screen
                HStack(spacing: 6) {
                    ForEach(Self.shots.indices, id: \.self) { i in
                        Circle().fill(i == shot ? Theme.accent : Theme.hairlineStrong).frame(width: 7, height: 7)
                            .onTapGesture { shot = i }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("game.title")).font(Theme.heading(22))
                    Text(loc.t("game.subtitle", GameROM.size / 1024)).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
                Text(loc.t("game.story")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    if hasOpenEmu {
                        Button(loc.t("game.play")) { GameROM.play() }.buttonStyle(SSMTButtonStyle(kind: .primary))
                    } else {
                        Button(loc.t("game.getOpenEmu")) { NSWorkspace.shared.open(URL(string: "https://openemu.org")!) }
                            .buttonStyle(SSMTButtonStyle(kind: .primary))
                    }
                    HStack(spacing: 8) {
                        Button(loc.t("game.save")) { GameROM.save() }.buttonStyle(SSMTButtonStyle())
                        Button(loc.t("game.reveal")) { GameROM.reveal() }.buttonStyle(SSMTButtonStyle())
                    }
                }
                controls
                Text(loc.t("game.run")).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(width: 300)
        }
        .padding(22)
        .background(Theme.background)
        .onReceive(timer) { _ in withAnimation(.easeInOut(duration: 0.2)) { shot = (shot + 1) % Self.shots.count } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasOpenEmu = GameROM.openEmu != nil
        }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let img = GameROM.screenshot(Self.shots[shot]) {
                Image(nsImage: img).interpolation(.none).resizable().aspectRatio(320.0 / 224.0, contentMode: .fit)
            }
        }
        .frame(width: 640, height: 448)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairlineStrong))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(loc.t("game.controls")).font(Theme.label(11)).foregroundStyle(Theme.textMuted)
            ForEach(["move", "punch", "kick", "jump", "items", "down", "start"], id: \.self) { k in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(loc.t("game.key.\(k)")).font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 74, alignment: .leading)
                    Text(loc.t("game.does.\(k)")).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }
}

/// The launcher's own window.
@MainActor
final class GameWindow {
    private static var window: NSWindow?

    static func show(localizer: Localizer) {
        ProfileCenter.shared.record("secret.game")
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1030, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = localizer.t("game.title")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: GameLauncherView().environmentObject(localizer))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                GameWindow.window?.contentView = nil
                GameWindow.window = nil
            }
        }
        window = w
    }
}
