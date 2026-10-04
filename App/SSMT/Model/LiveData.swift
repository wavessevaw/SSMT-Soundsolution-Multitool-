import SSMTCore
import SwiftUI

/// High-rate live data (≈10 updates/s), kept out of `AppModel` so a new snapshot redraws only the
/// small views that show live values, not the whole window.
@MainActor
final class LiveData: ObservableObject {
    @Published var snapshot: LiveSnapshot?
}

/// Tuner readings (≈4 updates/s while a tuner runs), observed only by the gauges and the controls
/// that depend on them.
@MainActor
final class TuningData: ObservableObject {
    @Published var alignment: AlignmentTuner.Reading?
    @Published var eq: EQTuner.Reading?
}

extension View {
    /// Injects the model, its live-data stores and the localizer.
    func ssmtEnvironment(_ model: AppModel, _ loc: Localizer) -> some View {
        environmentObject(model)
            .environmentObject(model.inputList)
            .environmentObject(model.show)
            .environmentObject(model.assist)
            .environmentObject(model.live)
            .environmentObject(model.tuning)
            .environmentObject(loc)
            .environmentObject(ProfileCenter.shared)
    }
}
