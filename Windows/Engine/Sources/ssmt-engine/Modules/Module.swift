import Foundation
import SSMTCore

/// One command from the interface: its name and fields, with typed accessors.
struct Command {
    let name: String
    let fields: [String: Any]

    func str(_ k: String) -> String? { fields[k] as? String }
    func int(_ k: String) -> Int? { (fields[k] as? NSNumber)?.intValue }
    func double(_ k: String) -> Double? { (fields[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { (fields[k] as? NSNumber)?.boolValue }
    /// A field holding a Codable value (sent by the interface as JSON).
    func decode<T: Decodable>(_ type: T.Type, _ k: String) -> T? {
        guard let v = fields[k], JSONSerialization.isValidJSONObject([v]),
              let d = try? JSONSerialization.data(withJSONObject: [v]) else { return nil }
        return (try? JSONDecoder().decode([T].self, from: d))?.first
    }
}

/// A function of the program in the engine (system setup, Ptch, Qtrl, handbook, profile). Each lives in its own
/// file under Modules/ and is listed in `Engine.modules`; FOH Assist is the engine itself (main.swift).
protocol EngineModule: AnyObject {
    /// Takes a command; false when the command is not this module's.
    func handle(_ c: Command, engine: Engine) -> Bool
    /// Called about 50 times a second.
    func tick(_ now: Date, engine: Engine)
}

extension EngineModule {
    func tick(_ now: Date, engine: Engine) {}
}

/// Every module, in the order commands are offered to them.
func makeModules() -> [EngineModule] {
    [ShowModule()]
}
