import Foundation
import LyrimuseCore
import OSLog

@MainActor
final class NotchUnknownPlayerPrompt: ObservableObject {
    static let shared = NotchUnknownPlayerPrompt()

    static let inert = NotchUnknownPlayerPrompt()

    struct Offer: Equatable {
        let bundleID: String

        let displayName: String

        let nowPlayingText: String
    }

    @Published private(set) var offer: Offer?

    @Published private(set) var isAlerting = false

    private let log = Logger(subsystem: "me.yudaotor.lyrimuse", category: "notify")
    private var alertTask: Task<Void, Never>?

    private var dismissedBundleID: String?

    private init() {}

    func update(offer next: Offer?) {
        guard let next else {
            dismissedBundleID = nil
            if offer != nil { offer = nil }
            endAlert()
            return
        }
        if next.bundleID != dismissedBundleID { dismissedBundleID = nil }
        let visible: Offer? = next.bundleID == dismissedBundleID ? nil : next
        if offer != visible { offer = visible }
    }

    @discardableResult
    func alert() -> Bool {
        guard let current = offer else { return false }
        alertTask?.cancel()
        if !isAlerting { isAlerting = true }
        alertTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UnknownPlayerAlert.notchAlertDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.alertTask = nil
            if self?.isAlerting == true { self?.isAlerting = false }
        }
        log.notice("notch alert for \(current.bundleID, privacy: .public)")
        return true
    }

    func dismiss() {
        guard let current = offer else { return }
        dismissedBundleID = current.bundleID
        offer = nil
        endAlert()
    }

    func trust() {
        guard let current = offer else { return }
        offer = nil
        endAlert()
        Task { await UnknownPlayerNotifier.trust(current.bundleID) }
    }

    private func endAlert() {
        alertTask?.cancel()
        alertTask = nil
        if isAlerting { isAlerting = false }
    }
}
