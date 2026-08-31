import Foundation

enum AppPaths {
    /// Application-Support-Ordner der App. Migriert einmalig den alten
    /// "DIYSpokenly"-Ordner (vor der Umbenennung zu Sprachacus), damit
    /// Verlauf und Einstellungen erhalten bleiben.
    static var supportDir: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("Sprachacus", isDirectory: true)
        let old = base.appendingPathComponent("DIYSpokenly", isDirectory: true)
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: new)
        }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        return new
    }
}
