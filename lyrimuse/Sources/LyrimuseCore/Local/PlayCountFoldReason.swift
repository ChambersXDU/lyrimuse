import Foundation

public enum PlayCountFoldReason: String, CaseIterable, Hashable, Codable {

    case caseOrSpacing

    case fullwidth

    case hanScript

    case catalogNoise

    case versionSuffix

    case bilingualTitle

    case artistCredit

    case artistAlias

    case titleAlias

    case other
}

public enum PlayCountFoldExplainer {

    public static func reasons(base: (artist: String, title: String),
                               variant: (artist: String, title: String)) -> [PlayCountFoldReason] {
        var out: [PlayCountFoldReason] = []
        if let r = artistReason(base.artist, variant.artist) { out.append(r) }
        if let r = titleReason(base.title, variant.title, baseArtist: base.artist, variantArtist: variant.artist),
           !out.contains(r) {
            out.append(r)
        }
        return out
    }

    private static func loose(_ s: String) -> String {
        PlayCountFold.stripSpaces(s.lowercased())
    }
    private static func nfkc(_ s: String) -> String {
        loose(s.precomposedStringWithCompatibilityMapping)
    }
    private static func norm(_ s: String) -> String {
        PlayCountFold.stripSpaces(PlayCountFold.normalized(s))
    }

    static func artistReason(_ a: String, _ b: String) -> PlayCountFoldReason? {
        if a == b { return nil }
        if loose(a) == loose(b) { return .caseOrSpacing }
        if nfkc(a) == nfkc(b) { return .fullwidth }
        if norm(a) == norm(b) { return .hanScript }
        if norm(ArtistCredit.mergeArtist(a)) == norm(ArtistCredit.mergeArtist(b)) { return .artistCredit }
        if PlayCountFold.canonicalArtistKey(a) == PlayCountFold.canonicalArtistKey(b) { return .artistAlias }
        return .other
    }

    static func titleReason(_ a: String, _ b: String,
                            baseArtist: String, variantArtist: String) -> PlayCountFoldReason? {
        if a == b { return nil }
        if let r = stagedTextReason(a, b) { return r }

        if PlayCountFold.familyKey(artist: baseArtist, title: a)
            == PlayCountFold.familyKey(artist: variantArtist, title: b) {
            return .titleAlias
        }
        return .other
    }

    public static func albumReason(base: String?, variant: String?) -> PlayCountFoldReason? {
        guard let a = base, let b = variant, a != b else { return nil }
        return stagedTextReason(a, b)
    }

    private static func stagedTextReason(_ a: String, _ b: String) -> PlayCountFoldReason? {
        if loose(a) == loose(b) { return .caseOrSpacing }
        if nfkc(a) == nfkc(b) { return .fullwidth }
        if norm(a) == norm(b) { return .hanScript }
        let noise = { (s: String) in
            PlayCountFold.stripSpaces(PlayCountFold.stripCatalogNoise(PlayCountFold.normalized(s)))
        }
        if noise(a) == noise(b) { return .catalogNoise }

        let version = { (s: String) in
            let stripped = PlayCountFold.stripCatalogNoise(PlayCountFold.normalized(s))
            return PlayCountFold.stripSpaces(
                PlayCountFold.stripCatalogNoise(PlayCountFold.canonicalizeVersionSuffix(stripped)))
        }
        if version(a) == version(b) { return .versionSuffix }
        if PlayCountFold.foldTitle(a) == PlayCountFold.foldTitle(b) { return .bilingualTitle }
        return nil
    }
}
