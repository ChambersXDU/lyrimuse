import LyrimuseCore
import SwiftUI

struct NotchRevealState {
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var contentOpacity: Double

    static let settled = NotchRevealState(widthFraction: 1, heightFraction: 1, contentOpacity: 1)
}

struct NotchRevealShape: Shape {
    var widthFraction: CGFloat
    var heightFraction: CGFloat

    static let bottomCornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(1, max(0, widthFraction))
        let height = rect.height * min(1, max(0, heightFraction))
        let visible = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)

        return NotchHangingShape(bottomCornerRadius: Self.bottomCornerRadius).path(in: visible)
    }
}

private struct NotchRevealContentOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct NotchHostClipsCardKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotchCardLayerActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {

    var notchRevealContentOpacity: Double {
        get { self[NotchRevealContentOpacityKey.self] }
        set { self[NotchRevealContentOpacityKey.self] = newValue }
    }

    var notchHostClipsCard: Bool {
        get { self[NotchHostClipsCardKey.self] }
        set { self[NotchHostClipsCardKey.self] = newValue }
    }

    var notchCardLayerActive: Bool {
        get { self[NotchCardLayerActiveKey.self] }
        set { self[NotchCardLayerActiveKey.self] = newValue }
    }
}
