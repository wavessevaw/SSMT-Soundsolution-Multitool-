import Foundation

/// The user's microphone calibration library and SPL calibration. The selection can be an imported
/// individual file or a built-in typical profile. Each app keeps it in its own place (the Mac app in
/// Application Support, the Windows engine in its data folder) in this one JSON format.
public struct CalibrationLibrary: Codable, Equatable, Sendable {
    public var microphones: [MicrophoneCalibration] = []
    public var selectedMicrophoneID: UUID?
    public var spl: SPLCalibration?

    public init(microphones: [MicrophoneCalibration] = [], selectedMicrophoneID: UUID? = nil, spl: SPLCalibration? = nil) {
        self.microphones = microphones
        self.selectedMicrophoneID = selectedMicrophoneID
        self.spl = spl
    }

    public var selectedMicrophone: MicrophoneCalibration? {
        guard let id = selectedMicrophoneID else { return nil }
        return microphones.first { $0.id == id } ?? MicrophoneProfiles.profile(id: id)?.calibration
    }

    public var selectedProfile: MicrophoneProfile? {
        selectedMicrophoneID.flatMap { MicrophoneProfiles.profile(id: $0) }
    }

    /// The library stored at `url`, or an empty one.
    public static func load(from url: URL) -> CalibrationLibrary {
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(CalibrationLibrary.self, from: data) else { return CalibrationLibrary() }
        return lib
    }

    public func save(to url: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
