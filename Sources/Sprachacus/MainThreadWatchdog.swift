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
    /// Zeitpunkt des letzten Ticks als **Betriebszeit**, nicht als Wanduhr.
    ///
    /// Wichtig: `mach_absolute_time` — die Grundlage von `DispatchTime` — steht
    /// im Ruhezustand still, die Wanduhr läuft weiter. Mit `Date()` sah ein
    /// zugeklappter Mac nach dem Aufwachen wie ein Hänger aus: Am 14.10. hat
    /// sich die App dadurch direkt nach dem Aufwachen selbst beendet
    /// („Hauptthread steht seit 920 s"), obwohl nur der Mac geschlafen hat.
    private var lastTick = DispatchTime.now().uptimeNanoseconds
    private var reportedHang = false
    private var timer: Timer?
    private var checker: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    private static func seconds(since start: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > start else { return 0 }
        return TimeInterval(now - start) / 1_000_000_000
    }

    func start() {
        // `.common` statt `.default`: Sonst zählte jeder modale Dialog und
        // jedes Scrollen als Hänger.
        let ticker = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.timer = ticker

        // Nach dem Aufwachen bewusst neu anfangen — unabhängig von der Uhr,
        // damit auch ein Sonderfall der Zeitmessung nicht zum Fehlalarm führt.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.lastTick = DispatchTime.now().uptimeNanoseconds
            self.reportedHang = false
            self.lock.unlock()
        }

        let checker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sprachacus.watchdog"))
        checker.schedule(deadline: .now() + 2, repeating: 2)
        checker.setEventHandler { [weak self] in self?.check() }
        checker.activate()
        self.checker = checker
    }

    private func tick() {
        lock.lock()
        let wasHanging = reportedHang
        let stuckFor = Self.seconds(since: lastTick)
        lastTick = DispatchTime.now().uptimeNanoseconds
        reportedHang = false
        lock.unlock()
        if wasHanging {
            log("Hauptthread reagiert wieder — er stand \(Int(stuckFor)) s")
        }
    }

    private func check() {
        lock.lock()
        let age = Self.seconds(since: lastTick)
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
