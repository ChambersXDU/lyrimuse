import AppKit
import Sparkle

@MainActor
final class SoftwareUpdateDriver: NSObject, SPUUserDriver {
    enum Event {

        case permissionRequest(reply: (SUUpdatePermissionResponse) -> Void)

        case userInitiatedCheck(cancel: () -> Void)

        case found(item: SUAppcastItem, state: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)

        case releaseNotes(SPUDownloadData)
        case releaseNotesFailed(any Error)

        case notFound(any Error, acknowledge: () -> Void)
        case failed(any Error, acknowledge: () -> Void)
        case downloadStarted(cancel: () -> Void)
        case downloadExpectedLength(UInt64)
        case downloadReceived(UInt64)
        case extractionStarted
        case extractionProgress(Double)

        case readyToInstall(reply: (SPUUserUpdateChoice) -> Void)

        case installing(applicationTerminated: Bool, retryTerminating: () -> Void)

        case installedAndRelaunched(Bool, acknowledge: () -> Void)

        case dismissed

        case focusRequested
    }

    var onEvent: ((Event) -> Void)?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        onEvent?(.permissionRequest(reply: reply))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onEvent?(.userInitiatedCheck(cancel: cancellation))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onEvent?(.found(item: appcastItem, state: state, reply: reply))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        onEvent?(.releaseNotes(downloadData))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        onEvent?(.releaseNotesFailed(error))
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.notFound(error, acknowledge: acknowledgement))
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onEvent?(.failed(error, acknowledge: acknowledgement))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onEvent?(.downloadStarted(cancel: cancellation))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onEvent?(.downloadExpectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onEvent?(.downloadReceived(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        onEvent?(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onEvent?(.extractionProgress(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        onEvent?(.readyToInstall(reply: reply))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        onEvent?(.installing(applicationTerminated: applicationTerminated, retryTerminating: retryTerminatingApplication))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onEvent?(.installedAndRelaunched(relaunched, acknowledge: acknowledgement))
    }

    func dismissUpdateInstallation() {
        onEvent?(.dismissed)
    }

    func showUpdateInFocus() {
        onEvent?(.focusRequested)
    }
}
