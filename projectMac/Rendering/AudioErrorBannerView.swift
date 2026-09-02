import SwiftUI

/// Announces a tap that failed or stopped delivering. Fades out on its own; the message
/// stays in `DebugOverlayView` until the next successful tap.
struct AudioErrorBannerView: View {
    let message: String

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .padding(24)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .allowsHitTesting(false)
        .task(id: message) {
            isVisible = true
            try? await Task.sleep(for: .seconds(8))
            isVisible = false
        }
    }
}
