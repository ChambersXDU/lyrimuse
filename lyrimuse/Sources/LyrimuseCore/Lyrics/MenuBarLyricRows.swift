import CoreGraphics
import Foundation

public enum MenuBarLyricRows {

    public static let buttonHeight: CGFloat = 22

    public static let mainPointSize: CGFloat = 10

    public static let secondaryPointSize: CGFloat = 9

    public static let tailFadeWidth: CGFloat = 14

    public struct Layout: Equatable, Sendable {
        public let mainY: CGFloat
        public let mainHeight: CGFloat
        public let secondaryY: CGFloat
        public let secondaryHeight: CGFloat
    }

    public static func layout(mainHeight: CGFloat, secondaryHeight: CGFloat, buttonHeight: CGFloat) -> Layout {
        let total = mainHeight + secondaryHeight
        if total <= buttonHeight {
            let gap = ((buttonHeight - total) / 2).rounded()
            return Layout(mainY: buttonHeight - gap - mainHeight, mainHeight: mainHeight,
                          secondaryY: gap, secondaryHeight: secondaryHeight)
        }
        return Layout(mainY: buttonHeight - mainHeight, mainHeight: mainHeight,
                      secondaryY: 0, secondaryHeight: secondaryHeight)
    }

    public static func secondaryOpacity(for kind: LyricSecondaryLine) -> Float {
        switch kind {
        case .off: return 0
        case .nextLine: return 0.55
        case .translation: return 0.75
        case .romanization: return 0.6
        }
    }
}
