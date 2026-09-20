import CoreGraphics

public enum OverlayCardGeometry {

    public static let duetStageReferenceWidth: CGFloat = 448
    public static let duetStageMinEm: CGFloat = 12

    public static func duetStageInset(availableWidth: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let stage = min(availableWidth, max(duetStageReferenceWidth, max(0, fontSize) * duetStageMinEm))
        return max(0, (availableWidth - stage) / 2)
    }

    public static func cardInsets(
        for side: LyricDuet.Side?, unit: CGFloat, stageInset: CGFloat = 0
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard let side else { return (0, 0) }
        let near = max(0, stageInset)
        switch side {
        case .leading: return (near, unit)
        case .trailing: return (unit, near)
        case .center: return (unit, unit)
        }
    }

    public static func controlsInsets(
        for side: LyricDuet.Side?, unit: CGFloat, stageInset: CGFloat = 0, cardHorizontalPadding: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let card = cardInsets(for: side, unit: unit, stageInset: stageInset)
        return (card.leading + cardHorizontalPadding, card.trailing + cardHorizontalPadding)
    }
}
