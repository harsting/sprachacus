import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case recording
        case assistRecording         // ⌥⌥: clipboard is context, user dictates an instruction
        case processing(String)      // status text, e.g. "Optimiere…"
        case downloading(Double)     // model download progress 0…1
        case success
        case error(String)
    }

    @Published var phase: Phase = .hidden
    @Published var bars: [Float] = Array(repeating: 0, count: OverlayModel.barCount)

    static let barCount = 28
    private var smoothed: Float = 0

    /// Push a new RMS sample; the waveform scrolls right-to-left.
    func pushLevel(_ rms: Float) {
        let scaled = min(1.0, rms * 16)
        smoothed = 0.7 * smoothed + 0.3 * scaled
        bars.removeFirst()
        bars.append(smoothed)
    }

    func resetLevels() {
        smoothed = 0
        bars = Array(repeating: 0, count: Self.barCount)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .hidden:
                EmptyView()
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
                WaveformView(bars: model.bars)
                Text("⌥ Stopp · esc Abbruch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            case .assistRecording:
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.purple)
                WaveformView(bars: model.bars)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text("⌥ fertig")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            case .processing(let status):
                PulsingDots()
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            case .downloading(let progress):
                ProgressView(value: max(0, min(1, progress)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text("Lade Sprachmodell… \(Int(progress * 100)) %")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Eingefügt")
                    .font(.system(size: 13, weight: .medium))
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 12))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 360, height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

struct WaveformView: View {
    let bars: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(bars[i]) * 30))
            }
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.12), value: bars)
    }
}

struct PulsingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.primary.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
