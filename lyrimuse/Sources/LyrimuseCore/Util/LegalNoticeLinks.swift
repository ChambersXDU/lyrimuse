import Foundation

public enum LegalNoticeLinks {
    public static let repo = "https://github.com/Yudaotor/lyrimuse"

    public static let thirdPartyLicensesOnGitHub = URL(string: repo + "/blob/main/THIRD_PARTY_LICENSES")!

    public static let licenseOnGitHub = URL(string: repo + "/blob/main/LICENSE")!

    public static func usageNoticeURL(language: String) -> URL {
        var components = URLComponents(string: repo)!
        components.path = "/Yudaotor/lyrimuse/blob/main/README.md"
        components.fragment = "license-and-copyright"
        return components.url!
    }
}
