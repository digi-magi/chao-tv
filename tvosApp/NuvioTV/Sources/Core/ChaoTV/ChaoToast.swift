import SwiftUI

/// Small "done" popup the house agent shows on the TV after acting on a
/// spoken request ("Added Blue Planet II to Library").
@MainActor
final class ChaoToast: ObservableObject {
    static let shared = ChaoToast()

    @Published private(set) var message: String?
    @Published private(set) var symbol: String = "checkmark.circle.fill"
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, symbol: String = "checkmark.circle.fill", seconds: Double = 3.5) {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            self.symbol = symbol
            self.message = message
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.message = nil }
        }
    }
}

struct ChaoToastView: View {
    @ObservedObject private var toast = ChaoToast.shared

    var body: some View {
        Group {
            if let message = toast.message {
                HStack(spacing: 14) {
                    Image(systemName: toast.symbol)
                        .font(.system(size: 30, weight: .semibold))
                    Text(message)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(.top, 40)
                .padding(.trailing, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .focusable(false)
    }
}
