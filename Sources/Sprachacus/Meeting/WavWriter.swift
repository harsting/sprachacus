import AVFoundation
import Foundation

/// Schreibt 16-kHz-Mono-Ton fortlaufend als WAV-Datei.
///
/// Bewusst nicht über `AVAudioFile`: Das schreibt die Längenangaben erst beim
/// Freigeben der Datei. Wird die App während einer Aufzeichnung beendet,
/// bleibt eine Datei zurück, die formal null Sekunden lang ist — die Daten
/// sind zwar da, aber kein Programm kann sie mehr öffnen. Genau das ist
/// passiert. Hier wird der Kopf regelmäßig nachgeführt, sodass die Datei zu
/// jedem Zeitpunkt lesbar ist.
final class WavWriter {
    private let handle: FileHandle
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var bytesWritten: UInt32 = 0
    private var bytesAtLastHeaderUpdate: UInt32 = 0

    /// Kopf spätestens alle ~10 Sekunden Ton nachführen (16000 × 2 Byte).
    private static let headerRefreshBytes: UInt32 = 16_000 * 2 * 10

    var secondsWritten: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(bytesWritten) / (16_000 * 2)
    }

    init?(url: URL, format: AVAudioFormat) {
        guard format.sampleRate == 16_000, format.channelCount == 1 else { return nil }
        targetFormat = format
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        writeHeader()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        let data: Data
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           let samples = buffer.int16ChannelData {
            data = Data(bytes: samples[0], count: Int(buffer.frameLength) * 2)
        } else {
            guard let converted = convert(buffer), let samples = converted.int16ChannelData else { return }
            data = Data(bytes: samples[0], count: Int(converted.frameLength) * 2)
        }
        guard !data.isEmpty else { return }

        handle.write(data)
        bytesWritten += UInt32(data.count)
        if bytesWritten - bytesAtLastHeaderUpdate >= Self.headerRefreshBytes {
            updateSizes()
        }
    }

    /// Schließt die Datei sauber ab. Mehrfach aufrufbar.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        updateSizes()
        try? handle.close()
    }

    // MARK: - Intern

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var served = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if served { outStatus.pointee = .noDataNow; return nil }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        return (status != .error && out.frameLength > 0) ? out : nil
    }

    private func writeHeader() {
        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        append("RIFF"); append32(36); append("WAVE")
        append("fmt "); append32(16)
        append16(1)                       // PCM
        append16(1)                       // Kanäle
        append32(16_000)                  // Abtastrate
        append32(16_000 * 2)              // Bytes pro Sekunde
        append16(2)                       // Blockausrichtung
        append16(16)                      // Bits pro Abtastwert
        append("data"); append32(0)
        handle.write(header)
    }

    /// Trägt die tatsächlichen Längen im Kopf nach und springt ans Ende zurück.
    private func updateSizes() {
        let position = handle.offsetInFile
        var riffSize = (36 + bytesWritten).littleEndian
        var dataSize = bytesWritten.littleEndian
        try? handle.seek(toOffset: 4)
        handle.write(Data(bytes: &riffSize, count: 4))
        try? handle.seek(toOffset: 40)
        handle.write(Data(bytes: &dataSize, count: 4))
        try? handle.seek(toOffset: position)
        bytesAtLastHeaderUpdate = bytesWritten
    }
}
