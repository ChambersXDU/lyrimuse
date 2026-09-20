import Foundation

public enum TitleAliasEvidence {

    public static func agrees(mbidA: String, albumA: String,
                              mbidB: String, albumB: String) -> Bool {
        let ma = mbidA.trimmingCharacters(in: .whitespaces)
        let mb = mbidB.trimmingCharacters(in: .whitespaces)
        if !ma.isEmpty, ma == mb { return true }

        let aa = albumA.trimmingCharacters(in: .whitespaces)
        let ab = albumB.trimmingCharacters(in: .whitespaces)
        guard !aa.isEmpty, !ab.isEmpty else { return true }

        return PlayCountFold.foldTitle(aa) == PlayCountFold.foldTitle(ab)
    }
}
