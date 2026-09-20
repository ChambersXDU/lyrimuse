import CoreGraphics

public enum LyricDuetLayout {

    public static let insetRatio: CGFloat = 0.15

    public static let maxInsetInEm: CGFloat = 4

    public static let nearInsetRatio: CGFloat = insetRatio / 2

    public static func insets(
        for side: LyricDuet.Side?, availableWidth: CGFloat, fontSize: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side, availableWidth > 0 else { return (0, 0) }
        let farInset = max(0, min(availableWidth * insetRatio, fontSize * maxInsetInEm))
        let nearInset = max(0, min(availableWidth * nearInsetRatio, fontSize * maxInsetInEm / 2))
        switch side {
        case .leading: return (nearInset, farInset)
        case .trailing: return (farInset, nearInset)
        case .center: return (farInset, farInset)
        }
    }
}
