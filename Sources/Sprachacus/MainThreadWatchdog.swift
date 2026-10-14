import AppKit
import Foundation

/// Überwacht, ob der Hauptthread noch reagiert.
///
/// Anlass: Ein Ringschluss zwischen der internen Warteschlange der
/// AVAudioEngine und dem Hauptthread hielt die App an. Nach außen sah man nur
/// ein Overlay, das sich nicht mehr schließen ließ — kein Fehler, keine
/// Meldung, kein Absturzbericht. Es gab auch keinen Weg zurück außer über das
/// Terminal.
///
/// Der Wächter tickt auf dem Hauptthread und prüft von einem Hintergrund-Thread
/// aus, wie alt der letzte Tick ist. Hängt der Hauptthread, wird das
/// protokolliert; hängt er dauerhaft, beendet sich die App selbst — ein
/// Neustart ist allemal besser als eine unbedienbare Oberfläche.
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    static var logURL: URL { AppPaths.supportDir.appendingPathComponent("hang.log") }

    /// Ab hier gilt der Hauptthread als hängend und es wird protokolliert.
    private static let warnAfter: TimeInterval = 10
    /// Ab hier beendet sich die App selbst.
    private static let terminateAfter: TimeInterval = 60
    private static let tickInterval: TimeInterval = 1

    private let lock = NSLock()
    private var lastTick = Date()
    private var reportedHang = false
    private var timer: Timer?
    private var checker: DispatchSourceTimer?

    func start() {
        // `.common` statt `.default`: Sonst zählte jeder modale Dialog und
        // jedes Scrollen als Hänger.
        let ticker = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.timer = ticker

        let checker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sprachacus.watchdog"))
        checker.schedule(deadline: .now() + 2, repeating: 2)
        checker.setEventHandler { [weak self] in self?.check() }
        checker.activate()
        self.checker = checker
    }

    private func tick() {
        lock.lock()
        let wasHanging = reportedHang
        let stuckFor = Date().timeIntervalSince(lastTick)
        lastTick = Date()
        reportedHang = false
        lock.unlock()
        if wasHanging {
            log("Hauptthread reagiert wieder — er stand \(Int(stuckFor)) s")
        }
    }

    private func check() {
        lock.lock()
        let age = Date().timeIntervalSince(lastTick)
        let alreadyReported = reportedHang
        if age > Self.warnAfter { reportedHang = true }
        lock.unlock()

        guard age > Self.warnAfter else { return }
        if !alreadyReported {
            log("Hauptthread reagiert seit \(Int(age)) s nicht — Bedienoberfläche steht")
        }
        if age > Self.terminateAfter {
            log("Hauptthread steht seit \(Int(age)) s — App beendet sich selbst, damit sie neu gestartet werden kann")
            exit(EXIT_FAILURE)
        }
    }

    private func log(_ message: String) {
        NSLog("WATCHDOG: \(message)")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Self.logURL)
        }
    }
}
