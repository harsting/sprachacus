import AVFoundation
import Accelerate
import ScreenCaptureKit

/// Captures the system audio mix (what the other participants say, heard
/// through headphones) via ScreenCaptureKit — audio only, no video output.
///
/// SCK taps the mix upstream of the output device, so switching headphones
/// mid-meeting does not interrupt the capture.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Called on the capture queue with freshly converted audio. Must consume
    /// the buffer synchronously.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Fires when the stream dies on its own (display reconfig, permission
    /// revoked, screen lock). The controller decides whether to restart.
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "de.sprachacus.systemaudio")
    private var isStopping = false

    var isRunning: Bool { stream != nil }

    // MARK: - Permission

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt and enrolls the app in System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Lifecycle

    func start() async throws {
        stop()
        isStopping = false

        // Also requires the screen-recording grant — throws when denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError(message: "Bildschirmaufnahme nicht erlaubt (Systemeinstellungen → Datenschutz → Bildschirm- & Systemaudioaufnahme)")
        }
        guard let display = content.displays.first else {
            throw CaptureError(message: "Kein Display gefunden")
        }

        // Whole-system audio: whole-display filter, exclude nothing.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is unavoidable in the config, but we never attach a .screen
        // output — this keeps it effectively audio-only.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        isStopping = true
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // The buffer list is owned by the CMSampleBuffer and only valid inside
        // this closure — consumers must copy/convert synchronously.
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            if let onLevel { onLevel(Self.rms(pcm)) }
            onBuffer?(pcm)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        guard !isStopping else { return }
        NSLog("SystemAudioCapture stopped: \(error.localizedDescription)")
        onStopped?(error)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(data, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }
}
