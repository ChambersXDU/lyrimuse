import AppKit
import Carbon.HIToolbox
import SwiftUI
import KeyboardShortcuts

final class ShortcutRecorderButton: NSButton {
    private let shortcutName: KeyboardShortcuts.Name
    private var eventMonitor: Any?
    private var windowResignObserver: NSObjectProtocol?
    private var isRecording = false {
        didSet { refreshTitle() }
    }

    weak var clearButton: NSButton?

    init(name: KeyboardShortcuts.Name) {
        self.shortcutName = name
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(handleClick)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let windowResignObserver { NotificationCenter.default.removeObserver(windowResignObserver) }
    }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, 150)
        return size
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        guard let window else { return }

        windowResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
            self?.stopRecording()
        }
    }

    @objc private func handleClick() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.isEmpty, Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return nil
        }

        if modifiers.isEmpty, Int(event.keyCode) == kVK_Tab {

            stopRecording()
            return event
        }

        if modifiers.isEmpty,
           event.specialKey == .delete || event.specialKey == .deleteForward || event.specialKey == .backspace {
            KeyboardShortcuts.setShortcut(nil, for: shortcutName)
            stopRecording()
            return nil
        }

        let requiredModifiers = modifiers.subtracting(.shift).intersection([.command, .option, .control])
        guard
            !requiredModifiers.isEmpty || modifiers.contains(.function),
            let shortcut = KeyboardShortcuts.Shortcut(event: event)
        else {
            NSSound.beep()
            return nil
        }

        if let conflict = ShortcutConflict.check(shortcut, event: event, recording: shortcutName) {
            let window = self.window
            stopRecording()
            ShortcutConflict.present(conflict, over: window)
            return nil
        }

        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        stopRecording()
        return nil
    }

    @objc func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: shortcutName)
        refreshTitle()
    }

    func refreshTitle() {
        if isRecording {
            title = L10n.t("请按下快捷键…")
            clearButton?.isHidden = true
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) {
            title = "\(shortcut)"
            clearButton?.isHidden = false
        } else {
            title = L10n.t("点击录制")
            clearButton?.isHidden = true
        }
    }
}

private final class ShortcutRecorderContainerView: NSView {
    let recordButton: ShortcutRecorderButton

    init(name: KeyboardShortcuts.Name) {
        let recordButton = ShortcutRecorderButton(name: name)
        self.recordButton = recordButton

        let clearButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.t("清除快捷键"))!,
            target: recordButton,
            action: #selector(ShortcutRecorderButton.clearShortcut)
        )
        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = L10n.t("清除快捷键")
        recordButton.clearButton = clearButton

        super.init(frame: .zero)

        recordButton.setContentHuggingPriority(.required, for: .horizontal)
        recordButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [clearButton, recordButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        recordButton.refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> ShortcutRecorderContainerView {
        ShortcutRecorderContainerView(name: name)
    }

    func updateNSView(_ nsView: ShortcutRecorderContainerView, context: Context) {
        nsView.recordButton.refreshTitle()
    }
}

struct ShortcutRecorder: View {
    private let title: String
    private let name: KeyboardShortcuts.Name

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
    }

    var body: some View {
        LabeledContent(title) {
            ShortcutRecorderRepresentable(name: name)
        }
    }
}

struct ShortcutRecorderControl: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        ShortcutRecorderRepresentable(name: name)
    }
}
