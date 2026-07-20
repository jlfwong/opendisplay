import SwiftUI

/// Sidecar-style toolbar strip to the left of the streamed content.
struct SidebarView: View {
    let width: CGFloat
    var onKey: (UInt16, Bool) -> Void

    var body: some View {
        Color(white: 0.15)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .center) {
                VStack(spacing: 10) {
                    SidebarKeyButton(label: "⌥", accessibilityLabel: "Option") { down in
                        onKey(WireKeyCode.option, down)
                    }
                    SidebarKeyButton(label: "⇧", accessibilityLabel: "Shift") { down in
                        onKey(WireKeyCode.shift, down)
                    }
                    SidebarKeyButton(label: "⌃", accessibilityLabel: "Control") { down in
                        onKey(WireKeyCode.control, down)
                    }
                    SidebarKeyButton(label: "Z", accessibilityLabel: "Z") { down in
                        onKey(WireKeyCode.z, down)
                    }
                    SidebarKeyButton(label: "R", accessibilityLabel: "R") { down in
                        onKey(WireKeyCode.r, down)
                    }
                    SidebarKeyButton(label: "A", accessibilityLabel: "A") { down in
                        onKey(WireKeyCode.a, down)
                    }
                }
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
