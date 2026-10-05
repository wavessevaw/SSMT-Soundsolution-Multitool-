import Foundation
import SSMTCore

/// The calibration library (SSMTCore `CalibrationLibrary`), persisted in Application Support.
extension CalibrationLibrary {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMT", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("calibration.json")
    }

    static func load() -> CalibrationLibrary { load(from: fileURL) }

    func save() { save(to: Self.fileURL) }
}
