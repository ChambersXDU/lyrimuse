import AppKit
import Foundation
import LyrimuseCore

enum LegalNotices {
    static var usageNoticeURL: URL { LegalNoticeLinks.usageNoticeURL(language: L10n.current) }

    static var bundledThirdPartyLicenses: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: nil)
    }

    static func openUsageNotice() {
        NSWorkspace.shared.open(usageNoticeURL)
    }

    static func openLicense() {
        NSWorkspace.shared.open(LegalNoticeLinks.licenseOnGitHub)
    }

    static func openThirdPartyLicenses() {
        guard let file = bundledThirdPartyLicenses,
              let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(LegalNoticeLinks.thirdPartyLicensesOnGitHub)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(LegalNoticeLinks.thirdPartyLicensesOnGitHub)
            }
        }
    }
}
