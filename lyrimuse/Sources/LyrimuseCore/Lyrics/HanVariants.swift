import Foundation

public enum HanVariants {

    public static let toSimplified: [Character: Character] = HanVariantsTable.toSimplified

    public static let icuGaps: Set<Character> = HanVariantsTable.icuGaps

    public static func normalizeToSimplified(_ text: String) -> String {
        guard text.contains(where: { toSimplified[$0] != nil }) else { return text }
        return String(text.map { toSimplified[$0] ?? $0 })
    }
}
