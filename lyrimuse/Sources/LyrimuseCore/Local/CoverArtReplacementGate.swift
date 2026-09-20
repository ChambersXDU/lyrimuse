import Foundation

public enum CoverArtReplacementGate {

    public enum Reason: Equatable, Sendable {

        case lowRes

        case notCoverShaped
    }

    public static let maxAspectSkew = 0.15

    public static func isCoverShaped(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let longer = Double(max(width, height))
        return Double(abs(width - height)) / longer <= maxAspectSkew
    }

    public static func reason(width: Int, height: Int, lowResThreshold: Int) -> Reason? {
        guard width > 0, height > 0 else { return nil }
        if !isCoverShaped(width: width, height: height) { return .notCoverShaped }
        if width <= lowResThreshold { return .lowRes }
        return nil
    }

    public static func accepts(candidateWidth: Int, candidateHeight: Int,
                               systemWidth: Int, reason: Reason) -> Bool {
        switch reason {
        case .lowRes:
            return candidateWidth > systemWidth
        case .notCoverShaped:
            return isCoverShaped(width: candidateWidth, height: candidateHeight)
        }
    }
}
