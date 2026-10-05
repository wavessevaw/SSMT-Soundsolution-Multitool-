import Foundation

// Parts of the open document that the Mac app kept in InputListStore, shared here so the Windows engine behaves the
// same: the document a first launch starts with and the file name offered when saving or exporting.
extension InputListDocument {
    /// A new document starts with a small band so every tool is visible right away.
    public static var starter: InputListDocument {
        var d = InputListDocument()
        d.stage.add(.riser, at: (5, 4.5), label: "Drum riser")
        d.stage.add(.drumKit, at: (5, 4.5), label: "Drums")
        d.stage.add(.person, at: (5, 1.2), label: "Lead vocal")
        d.stage.add(.wedge, at: (5, 0.4), label: "Mix 1")
        d.stage.add(.text, at: (5, 0.0), label: "Audience")
        return d
    }

    /// File name from the artist / event ("Band - Club").
    public var suggestedName: String {
        let parts = [artist, event].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = parts.isEmpty ? "Ptch" : parts.joined(separator: " - ")
        return name.replacingOccurrences(of: "/", with: "-")
    }
}
