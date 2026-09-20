import AppKit
import SwiftUI

@MainActor
final class MenuBarPositionHintController {
    private var popover: NSPopover?
    private var closeObserver: NSObjectProtocol?
    private var autoDismissWorkItem: DispatchWorkItem?

    private static let autoDismissSeconds: TimeInterval = 8

    func show(relativeTo button: NSStatusBarButton) {
        guard popover == nil else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let content = MenuBarPositionHintView(dismiss: { [weak pop] in pop?.performClose(nil) })
        pop.contentViewController = NSHostingController(rootView: content)
        popover = pop
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: pop, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        pop.contentViewController?.view.window?.collectionBehavior
            .formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])

        let work = DispatchWorkItem { [weak pop] in pop?.performClose(nil) }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissSeconds, execute: work)
    }

    private func teardown() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        popover = nil
    }
}

private struct MenuBarPositionHintView: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("按住 ⌘ 拖拽这个图标，可以把它移动到菜单栏里你喜欢的位置。"))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("知道了"), action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
