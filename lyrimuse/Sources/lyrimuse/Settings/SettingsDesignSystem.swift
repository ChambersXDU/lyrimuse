import AppKit
import LyrimuseCore
import SwiftUI

extension View {

    @ViewBuilder
    func settingsCardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        } else {
            background(shape.fill(Color.primary.opacity(0.05)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func settingsSearchFieldBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        } else {
            background(shape.fill(.quaternary.opacity(0.7)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func settingsProminentGlassButton(tint: Color) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }

    @ViewBuilder
    func settingsGlassButtons() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    @ViewBuilder
    func clearGlassCapsule(rim: Color) -> some View {
        if #available(macOS 26.0, *) {

            glassEffect(.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(rim, lineWidth: 0.5))
        } else {
            background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(rim, lineWidth: 0.5))
        }
    }
}

struct SettingsGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension Animation {

    static var settingsCardReveal: Animation { .smooth(duration: 0.3) }
}

extension AnyTransition {

    static var settingsCard: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

private struct SettingsPageWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FixedWidthScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            content()

                .frame(width: measuredWidth > 0 ? measuredWidth : nil)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: SettingsPageWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(SettingsPageWidthKey.self) { measuredWidth = $0 }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String

    var heroImage: NSImage?
    var heroSize: CGFloat = 88

    var showsHeader: Bool = true
    @ViewBuilder let content: () -> Content

    static var maxCardColumnWidth: CGFloat { 600 }

    var body: some View {
        FixedWidthScrollView {

            SettingsGlassContainer(spacing: 0) {
                VStack(spacing: 14) {
                    if showsHeader { header }
                    content()
                }
            }
            .frame(maxWidth: Self.maxCardColumnWidth)

            .padding(.top, 26)
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }

        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 6) {
            if let heroImage {
                Image(nsImage: heroImage)
                    .resizable()
                    .frame(width: heroSize, height: heroSize)
                    .padding(.bottom, 2)
            }
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 6)
    }
}

struct SettingsPageWithStickyHeader<Header: View, Page: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let page: () -> Page

    var body: some View {
        VStack(spacing: 0) {
            header()
                .frame(maxWidth: .infinity)

                .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            page()
        }
    }
}

struct SettingsPageCustomHeader<Header: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        FixedWidthScrollView {

            SettingsGlassContainer(spacing: 0) {
                VStack(spacing: 14) {
                    header()
                        .padding(.bottom, 6)
                    content()
                }
            }
            .frame(maxWidth: SettingsPage<EmptyView>.maxCardColumnWidth)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }

        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }

        .settingsCardBackground(cornerRadius: 10)
    }
}

struct CardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, SettingsRowMetrics.textLeadingInset)
    }
}

enum SettingsRowMetrics {
    static let iconWidth: CGFloat = 20
    static let iconTextSpacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 11

    static var textLeadingInset: CGFloat { horizontalPadding + iconWidth + iconTextSpacing }
}

struct SettingsCardHeader<Trailing: View>: View {
    let title: String

    var subtitle: String?
    var help: String?

    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 7)

        .settingsSearchHighlight(title: title)
    }
}

extension SettingsCardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, help: String? = nil) {
        self.init(title: title, subtitle: subtitle, help: help) { EmptyView() }
    }
}

struct SettingsRow<Trailing: View>: View {
    var icon: String?

    var iconTint: Color?

    var iconImage: NSImage?
    let title: String
    var subtitle: String?

    var help: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {

            Group {
                if let iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .frame(width: SettingsRowMetrics.iconWidth, height: SettingsRowMetrics.iconWidth)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(iconTint ?? Color.secondary)

                        .environment(\.locale, Locale(identifier: "en"))
                }
            }
            .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)

            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13))
                }
            }

            Spacer(minLength: 12)

            trailing()

                .labelsHidden()

                .toggleStyle(.switch)
                .settingsGlassButtons()
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)

        .settingsSearchHighlight(title: title)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String? = nil, iconTint: Color? = nil, iconImage: NSImage? = nil, title: String, subtitle: String? = nil, help: String? = nil) {
        self.init(icon: icon, iconTint: iconTint, iconImage: iconImage, title: title, subtitle: subtitle, help: help) { EmptyView() }
    }
}

struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, role: .destructive, action: action)
            .foregroundStyle(.red)
            .tint(.red)
    }
}

struct SettingsNote<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        SettingsRawRow(insetToText: true) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSubRow<Trailing: View>: View {
    var title: String?

    var subtitle: String?

    var trailingWidth: CGFloat?

    var help: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13))
                }
            }
            Spacer(minLength: 10)
            trailing()

                .labelsHidden()
                .toggleStyle(.switch)
                .settingsGlassButtons()
                .frame(maxWidth: trailingWidth)
        }

        .padding(.leading, SettingsRowMetrics.textLeadingInset - 12)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .settingsSearchHighlight(title: title)
    }
}

struct SettingsRawRow<Content: View>: View {
    var insetToText = false

    var icon: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowMetrics.iconTextSpacing) {
            if insetToText {
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                            .environment(\.locale, Locale(identifier: "en"))
                    }
                }
                .frame(width: SettingsRowMetrics.iconWidth, alignment: .center)
                .padding(.top, 1)
            }
            content()
        }

        .padding(.leading, SettingsRowMetrics.horizontalPadding)
        .padding(.trailing, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsPopoverShell<Content: View>: View {
    let title: String

    var help: String?

    var width: CGFloat = 380
    @ViewBuilder let content: () -> Content

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsCardHeader(title: title, help: help)
                CardDivider()
                content()
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PopoverContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(width: width)

        .frame(height: measuredHeight > 0 ? min(measuredHeight, 460) : nil)
        .onPreferenceChange(PopoverContentHeightKey.self) { measuredHeight = $0 }
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum SettingsToggleSummary {
    @MainActor
    static func text(_ entries: [(title: String, isOn: Bool)]) -> String {
        let onTitles = entries.filter { $0.isOn }.map { $0.title }
        if onTitles.count == entries.count { return L10n.t("全部开启") }
        if onTitles.isEmpty { return L10n.t("全部关闭") }
        return ListFormatter.localizedString(byJoining: onTitles)
    }
}

struct SettingsProportionBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Int
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 6
    var gap: CGFloat = 1.5
    var minSegmentWidth: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.value > 0 }

            let widths = ProportionBar.widths(
                values: visible.map(\.value), available: proxy.size.width,
                gap: gap, minWidth: minSegmentWidth)
            HStack(spacing: gap) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: widths[index])
                }
            }
        }

        .frame(height: height)

        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

struct SteppedSlider: View {
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self.value = value
        self.range = range
        self.step = step
    }

    var body: some View {

        Slider(value: Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = Self.snap($0, in: range, step: step) }
        ), in: range)
    }

    static func snap(_ raw: Double, in range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let quantized = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        return min(max(quantized, range.lowerBound), range.upperBound)
    }
}
