import SwiftUI

struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
            .accessibilityHidden(true)
    }
}
