public enum OverlayDuetAlignmentOverride: String, Codable, Hashable, CaseIterable, Sendable {
    case automatic
    case center
    case leading
    case trailing

    public func effectiveAlignmentSide(realSide: LyricDuet.Side?) -> LyricDuet.Side {
        switch self {
        case .automatic: return realSide ?? .center
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    public func effectiveDecorationSide(realSide: LyricDuet.Side?) -> LyricDuet.Side? {
        self == .automatic ? realSide : nil
    }
}
