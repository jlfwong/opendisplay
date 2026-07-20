import SwiftUI

/// Sidecar-style toolbar strip to the left of the streamed content.
struct SidebarView: View {
    let width: CGFloat
    var onKey: (UInt16, Bool) -> Void

    var body: some View {
        Color(white: 0.15)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                VStack(spacing: 10) {
                    SidebarKeyButton(label: "⌥", accessibilityLabel: "Option") { down in
                        onKey(WireKeyCode.option, down)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
                .padding(.horizontal, 8)
            }
    }
}

private struct SidebarKeyButton: View {
    let label: String
    let accessibilityLabel: String
    var onPress: (Bool) -> Void

    @State private var isPressing = false

    var body: some View {
        Text(label)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(isPressing ? 1 : 0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(white: isPressing ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(accessibilityLabel)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                guard pressing != isPressing else { return }
                isPressing = pressing
                onPress(pressing)
            }, perform: {})
    }
}
