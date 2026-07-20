import SwiftUI

/// Sidecar-style toolbar strip to the left of the streamed content.
/// Milestone 1: empty chrome; buttons will be added in a later pass.
struct SidebarView: View {
    let width: CGFloat

    var body: some View {
        Color(white: 0.15)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}
