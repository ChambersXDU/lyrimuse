import Foundation

public struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    public enum PreKind: String, CaseIterable {
        case alpha, beta, rc

        public var buildOffset: Int {
            switch self {
            case .alpha: return 0
            case .beta: return 100
            case .rc: return 500
            }
        }

        public var maxNumber: Int {
            switch self {
            case .alpha: return 99
            case .beta: return 399
            case .rc: return 499
            }
        }
    }

    public static let stableBuild = 1000

    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preKind: PreKind?

    public let preNumber: Int

    public init?(tag: String) {
        var s = Substring(tag)
        if s.hasPrefix("v") { s.removeFirst() }
        let dash = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = dash[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(Self.isCanonicalNumber) else { return nil }
        major = Int(core[0])!
        minor = Int(core[1])!
        patch = Int(core[2])!
        if dash.count == 1 {
            preKind = nil
            preNumber = 0
            return
        }
        let pre = dash[1].split(separator: ".", omittingEmptySubsequences: false)
        guard pre.count == 2, let kind = PreKind(rawValue: String(pre[0])),
              Self.isCanonicalNumber(pre[1]), let n = Int(pre[1]), n >= 1, n <= kind.maxNumber else { return nil }
        preKind = kind
        preNumber = n
    }

    private static func isCanonicalNumber(_ s: Substring) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return s == "0" || s.first != "0"
    }

    public var isPrerelease: Bool { preKind != nil }

    public var buildComponent: Int { preKind.map { $0.buildOffset + preNumber } ?? Self.stableBuild }

    public var displayString: String {
        if let preKind { return "\(major).\(minor).\(patch)-\(preKind.rawValue).\(preNumber)" }
        return "\(major).\(minor).\(patch)"
    }

    public var buildNumberString: String { "\(major).\(minor).\(patch).\(buildComponent)" }
    public var description: String { displayString }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.buildComponent) < (rhs.major, rhs.minor, rhs.patch, rhs.buildComponent)
    }
}
