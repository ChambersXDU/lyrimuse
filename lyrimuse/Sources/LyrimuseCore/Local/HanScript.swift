import Foundation

enum HanScript {

    static func sibling(_ s: String) -> String? {
        let t2s = transform(s, "Hant-Hans")
        if t2s != s { return t2s }
        let s2t = transform(s, "Hans-Hant")
        if s2t != s { return s2t }
        return nil
    }

    private static func transform(_ s: String, _ id: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, id as CFString, false)
        return m as String
    }
}
