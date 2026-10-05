import Foundation
import SSMTCore

/// The hidden game's launcher (App/SSMT/Game/GameWindow.swift, GameROM): where the ROM copy lives outside the app
/// (`<dataDir>/Game`, as Application Support/SSMT/Game on the Mac) and whether an emulator is installed. On Windows
/// the copy gets the Genesis extension .gen (.md opens Markdown editors there); "Play" opens it with the program
/// Windows associates with .gen files, as the Mac hands the .md file to OpenEmu.
///
/// Command: gameInfo. Event: gameInfo {dir, path, fileName, hasEmulator, emulator}.
final class GameModule: EngineModule {
    static let fileName = "soundcheck-of-the-dead.gen"

    func handle(_ c: Command, engine: Engine) -> Bool {
        guard c.name == "gameInfo" else { return false }
        let dir = engine.dataDir.appendingPathComponent("Game", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let emulator = Self.associatedProgram(".gen")
        Out.emit("gameInfo", ["dir": dir.path, "path": dir.appendingPathComponent(Self.fileName).path,
                              "fileName": Self.fileName, "hasEmulator": emulator != nil, "emulator": emulator ?? ""])
        return true
    }

    /// The file type Windows associates with an extension (`assoc .gen` → `.gen=BlastEm.gen`), nil when none.
    static func associatedProgram(_ ext: String) -> String? {
        #if os(Windows)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        p.arguments = ["/d", "/c", "assoc", ext]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8),
              let eq = s.firstIndex(of: "=") else { return nil }
        let type = s[s.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? nil : type
        #else
        return nil
        #endif
    }
}
