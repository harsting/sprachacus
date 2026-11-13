import AVFoundation
import Foundation

/// Nimmt Ton entgegen, bevor die Erkennung bereit ist, und reicht ihn nach.
///
/// Der Grund: Das Öffnen einer `SpeechAnalyzer`-Sitzung dauert spürbar
/// (gemessen rund eine Sekunde). Vorher wurde das Mikrofon erst *danach*
/// gestartet — in dieser Zeit war die Taste längst gedrückt, der Nutzer sprach
/// schon, und die ersten Worte fehlten. Jetzt läuft die Aufnahme sofort, der
/// Ton wartet so lange hier.
final class BufferedAudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: TimeInterval = 0
    private weak var target: Transcriber?

    /// Mehr als das wird nicht vorgehalten — falls die Erkennung gar nicht
    /// aufmacht, soll der Speicher nicht mitwachsen.
    private static let maximumSeconds: TimeInterval = 30

    /// Wird aus dem Audio-Thread aufgerufen.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let target {
            lock.unlock()
            target.feed(buffer)
            return
        }
        if let copy = Self.copy(buffer) {
            pending.append(copy)
            pendingSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            while pendingSeconds > Self.maximumSeconds, let first = pending.first {
                pendingSeconds -= Double(first.frameLength) / first.format.sampleRate
                pending.removeFirst()
            }
        }
        lock.unlock()
    }

    /// Hängt die fertige Erkennung an und reicht alles Gepufferte nach.
    func attach(_ transcriber: Transcriber) {
        lock.lock()
        let buffered = pending
        pending = []
        pendingSeconds = 0
        target = transcriber
        lock.unlock()
        for buffer in buffered { transcriber.feed(buffer) }
    }

    func detach() {
        lock.lock()
        target = nil
        pending = []
        pendingSeconds = 0
        lock.unlock()
    }

    /// Kopiert einen Puffer aus dem Audio-Tap. Nötig, weil der dem System
    /// gehört und über den Rückruf hinaus nicht festgehalten werden darf.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                          frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels { target[channel].update(from: source[channel], count: frames) }
            return copy
        }
        if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            for channel in 0..<channels { target[channel].update(from: source[channel], count: frames) }
            return copy
        }
        return nil
    }
}
