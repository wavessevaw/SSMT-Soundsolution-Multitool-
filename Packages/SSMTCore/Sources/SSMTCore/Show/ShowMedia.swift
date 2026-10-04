import Foundation

/// The show's media folder ("bundle"): copies of the show's audio next to the show file.
public enum ShowMedia {
    /// Copies files into `folder`. A file already in the folder is used as is; an identical file already there (same
    /// name, same contents) is reused; a different file with the same name gets a number ("Intro 2.wav"). A file that
    /// cannot be copied is reported with the system's reason and left out.
    public static func copy(_ urls: [URL], into folder: URL) -> (copied: [URL], errors: [String]) {
        let fm = FileManager.default
        var copied: [URL] = []
        var errors: [String] = []
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return ([], ["\(folder.path): \(error.localizedDescription)"])
        }
        let base = folder.standardizedFileURL.path
        for url in urls {
            let src = url.standardizedFileURL
            if src.deletingLastPathComponent().path == base { copied.append(src); continue }
            guard fm.fileExists(atPath: src.path) else {
                errors.append("\(src.lastPathComponent): not found")
                continue
            }
            let name = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
            var dest = folder.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) && !fm.contentsEqual(atPath: dest.path, andPath: src.path) {
                dest = folder.appendingPathComponent("\(name) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                n += 1
            }
            do {
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
                copied.append(dest)
            } catch {
                errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (copied, errors)
    }
}
