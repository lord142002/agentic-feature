import SwiftUI

struct VoiceActivityView: View {
    @ObservedObject var meter: VoiceActivityMeter
    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    enum Mode {
        case idle
        case listening
        case disabled
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(0..<4) { index in
                Capsule(style: .continuous)
                    .fill(mode == .disabled
                          ? LinearGradient(colors: [BibblesStyle.muted.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [Color.white.opacity(0.9), BibblesStyle.barColors[index]],
                                           startPoint: .top, endPoint: .bottom))
                    .frame(width: 4.2, height: height(for: index))
                    .shadow(color: mode == .disabled ? .clear : BibblesStyle.barColors[index].opacity(0.48),
                            radius: mode == .listening ? 5 : 3)
            }
        }
        .frame(width: 31, height: 29)
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 190, damping: 24), value: meter.bars)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .onDisappear { breathing = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func height(for index: Int) -> CGFloat {
        switch mode {
        case .disabled: return 4.2
        case .idle: return 5.5 + (breathing && !reduceMotion ? BibblesStyle.barHeights[index] * 6 : 0)
        case .listening:
            return reduceMotion ? 11 : 5.5 + meter.bars[index] * 23
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .idle: return "Bibbles is ready"
        case .listening: return "Microphone is listening"
        case .disabled: return "Microphone is inactive"
        }
    }
}
