import AppKit
import SwiftUI
import LyrimuseCore

@MainActor
extension LyricsSurface {

    var symbolName: String {
        switch self {
        case .overlay: return "captions.bubble"
        case .notch: return "rectangle.topthird.inset.filled"
        case .menuBar: return "menubar.rectangle"
        }
    }

    var panelTitle: String {
        switch self {
        case .overlay: return L10n.t("悬浮歌词")

        case .notch: return L10n.t("灵动岛歌词")
        case .menuBar: return L10n.t("菜单栏歌词")
        }
    }

    var isEnabled: Bool {
        switch self {
        case .overlay: return AppSettings.shared.classicOverlayEnabled
        case .notch: return AppSettings.shared.notchOverlayEnabled
        case .menuBar: return AppSettings.shared.showLyricsInMenuBar
        }
    }
}

struct TileMouseRouter: NSViewRepresentable {

    var holdSeconds: TimeInterval = 0.35
    var onPrimary: () -> Void
    var onSecondary: () -> Void
    var onPressingChange: (Bool) -> Void
    var onHoverChange: (Bool) -> Void

    var toolTip: String?

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: RouterView, context: Context) { apply(to: view) }

    private func apply(to view: RouterView) {
        view.holdSeconds = holdSeconds
        view.onPrimary = onPrimary
        view.onSecondary = onSecondary
        view.onPressingChange = onPressingChange
        view.onHoverChange = onHoverChange
        view.toolTip = toolTip
    }

    final class RouterView: NSView {
        var holdSeconds: TimeInterval = 0.35
        var onPrimary: (() -> Void)?
        var onSecondary: (() -> Void)?
        var onPressingChange: ((Bool) -> Void)?
        var onHoverChange: ((Bool) -> Void)?

        private var press = TilePressState()
        private var holdWork: DispatchWorkItem?

        private var hoverArea: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let text = toolTip else { return }
            toolTip = nil
            toolTip = text
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let hoverArea { removeTrackingArea(hoverArea) }

            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

        override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

        override func mouseDown(with event: NSEvent) {

            dispatch(press.handle(.down))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dispatch(self.press.handle(.holdElapsed))
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
        }

        override func mouseDragged(with event: NSEvent) {
            let inside = isInside(event)

            if !inside { holdWork?.cancel() }
            dispatch(press.handle(inside ? .dragInside : .dragOutside))
        }

        override func mouseUp(with event: NSEvent) {
            holdWork?.cancel()

            if !isInside(event) { dispatch(press.handle(.dragOutside)) }
            dispatch(press.handle(.up))
        }

        override func rightMouseDown(with event: NSEvent) {
            holdWork?.cancel()
            dispatch(press.handle(.secondaryClick))
        }

        override func rightMouseUp(with event: NSEvent) {}

        private func isInside(_ event: NSEvent) -> Bool {
            bounds.contains(convert(event.locationInWindow, from: nil))
        }

        private func dispatch(_ action: TilePressState.Action) {
            onPressingChange?(press.isPressing)
            switch action {
            case .none: break
            case .primary: onPrimary?()
            case .secondary: onSecondary?()
            }
        }
    }
}

struct PanelQuickSettings: View {
    let surface: LyricsSurface

    let toggle: () -> Void
    let back: () -> Void
    let close: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            VStack(spacing: 7) { rows }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            Divider().opacity(0.6)
            footer
        }
        .background(Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("返回"))
            Image(systemName: surface.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(surface.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(surface.panelTitle).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(get: { surface.isEnabled }, set: { _ in toggle() }))
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var rows: some View {
        switch surface {
        case .overlay:
            sliderRow(L10n.t("字号"), value: $settings.fontSize, range: 14...36)
            sliderRow(L10n.t("宽度"), value: Binding(
                get: { settings.overlayWidth },
                set: { newValue in
                    settings.overlayWidth = newValue

                    if settings.classicOverlayEnabled {
                        LyricsOverlayWindowController.shared.setWidth(newValue)
                    }
                }
            ), range: OverlayEditorStage.widthRange, step: 10)

            alignmentRow(selection: $settings.overlayDuetAlignmentOverride,
                         options: Array(OverlayDuetAlignmentOverride.allCases),
                         label: OverlayAlignmentSegmentedControl.label(for:))
            toggleRow(L10n.t("锁定位置"),
                      help: L10n.t("解锁后鼠标点击会穿到桌面上；拖动方式见设置里的「拖动前先长按」"),
                      isOn: Binding(
                        get: { settings.lockPosition },
                        set: { newValue in
                            settings.lockPosition = newValue
                            if settings.classicOverlayEnabled {
                                LyricsOverlayWindowController.shared.setLocked(newValue)
                            }
                        }))
        case .notch:
            row(L10n.t("风格")) {
                Picker("", selection: $settings.notchCardStyle) {
                    ForEach(NotchCardStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }

            sliderRow(L10n.t("宽度"), value: Binding(
                get: { settings.notchContentWidth },
                set: { NotchEditorStage.commitWidths(steady: $0) }
            ), range: NotchEditorStage.usableWidthRangeOnCurrentScreen, step: 10,
               displayValue: { NotchEditorStage.effectiveWidth(baseWidth: $0) })

            sliderRow(L10n.t("展开宽度"), value: Binding(
                get: { settings.notchExpandedContentWidth },
                set: { NotchEditorStage.commitWidths(expanded: $0) }
            ), range: NotchEditorStage.usableExpandedWidthRangeOnCurrentScreen, step: 10,
               displayValue: {
                   NotchEditorStage.effectiveExpandedWidth(steadyBase: settings.notchContentWidth,
                                                           expandedBase: $0)
               })

            toggleRow(L10n.t("显示歌词"), isOn: $settings.notchShowLyrics)

            if settings.notchShowLyrics {
                alignmentRow(selection: $settings.notchLyricsAlignment,
                             options: LyricsRestingAlignment.notchOptions,
                             label: LyricsAlignmentSegmentedControl.label(for:))
            }
        case .menuBar:
            row(L10n.t("宽度模式")) {
                Picker("", selection: $settings.menuBarLyricsWidthMode) {
                    Text(L10n.t("固定")).tag(MenuBarLyricsWidthMode.fixed)

                    Text(L10n.t("自适应")).tag(MenuBarLyricsWidthMode.adaptive)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            sliderRow(L10n.t("最大宽度"), value: Binding(
                get: { Double(settings.menuBarLyricsWidth) },
                set: { settings.menuBarLyricsWidth = CGFloat(($0 / 10).rounded() * 10) }
            ), range: 80...600, step: 10)

            if settings.menuBarLyricsWidthMode == .fixed {
                alignmentRow(selection: $settings.menuBarLyricsAlignment,
                             options: LyricsRestingAlignment.menuBarOptions,
                             label: LyricsAlignmentSegmentedControl.label(for:))
            }

            Text(L10n.t("收起面板后生效"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row<Control: View>(_ title: String, help: String? = nil,
                                   @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            control()
        }
        .frame(minHeight: 20)
        .modifier(OptionalHelp(text: help))
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 1,
                           displayValue: ((Double) -> Double)? = nil) -> some View {
        row(title) {
            HStack(spacing: 6) {

                SteppedSlider(value: value, in: range, step: step)
                    .controlSize(.mini)
                    .frame(width: 128)
                Text(String(format: L10n.t("%@pt"),
                            "\(Int(displayValue?(value.wrappedValue) ?? value.wrappedValue))"))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private func toggleRow(_ title: String, help: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        row(title, help: help) {
            Toggle("", isOn: isOn).labelsHidden().controlSize(.mini)
        }
    }

    private func alignmentRow<Value: Hashable>(
        selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String
    ) -> some View {
        row(L10n.t("对齐方式")) {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var footer: some View {
        Button {
            close()

            UserDefaults.standard.set(surface.appearanceSectionRawValue,
                                      forKey: LyricsSurface.appearanceSectionStorageKey)
            AppActions.shared.requestSettings(.tab(.appearance))
            AppActions.shared.openSettings?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape").font(.system(size: 10.5))
                Text(L10n.t("全部设置…")).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
