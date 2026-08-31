import AppKit
import ApplicationServices
import AVFoundation
import Speech

/// TCC onboarding. Order matters:
/// 1. Accessibility (hotkey monitor + paste) — system dialog, user toggles in
///    System Settings; we poll so no relaunch is needed.
/// 2. Speech recognition (defensive — SpeechAnalyzer is fully on-device).
/// 3. Microphone.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestSpeechRecognition() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
