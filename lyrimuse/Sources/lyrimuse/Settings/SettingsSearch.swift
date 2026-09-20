import AppKit
import Combine
import LyrimuseCore
import SwiftUI

struct SettingsSearchHit: Identifiable, Hashable {
    let entry: SettingsSearchEntry

    let title: String

    let alternateTitles: [String]
    let breadcrumb: String

    let secondary: [String]

    var id: String { entry.id }
    var highlightTitles: Set<String> { Set([title] + alternateTitles) }
}

@MainActor
final class SettingsSearchIndex {
    static let shared = SettingsSearchIndex()

    private var cached: (language: String, hits: [SettingsSearchHit])?
    private var tables: [String: [String: String]] = [:]

    func search(_ query: String) -> [SettingsSearchHit] {
        let all = hits()
        return SettingsSearchMatcher.ranked(all, query: query, title: { $0.title }, secondary: { $0.secondary })
    }

    private func hits() -> [SettingsSearchHit] {
        let language = L10n.current
        if let cached, cached.language == language { return cached.hits }
        let built = SettingsSearchCatalog.entries.map(localize)
        cached = (language, built)
        return built
    }

    private func localize(_ entry: SettingsSearchEntry) -> SettingsSearchHit {
        let title = L10n.t(entry.titleKey)
        let alternates = entry.alternateTitleKeys.map(L10n.t)
        let path = entry.pathKeys.map(L10n.t)
        var secondary: [String] = alternates + entry.keywords + path
        secondary.append(entry.titleKey)
        secondary.append(contentsOf: entry.alternateTitleKeys)
        secondary.append(contentsOf: entry.pathKeys)

        for language in ["en", "zh-hant", "zh-hans"] where language != L10n.current {
            let table = stringsTable(language)
            for key in [entry.titleKey] + entry.alternateTitleKeys {
                if let translated = table[key] { secondary.append(translated) }
            }
        }
        return SettingsSearchHit(entry: entry, title: title, alternateTitles: alternates,
                                 breadcrumb: path.joined(separator: " › "), secondary: secondary)
    }

    private func stringsTable(_ language: String) -> [String: String] {
        if let table = tables[language] { return table }
        var table: [String: String] = [:]
        if let dir = Bundle.main.path(forResource: language, ofType: "lproj"),
           let dict = NSDictionary(contentsOfFile: dir + "/Localizable.strings") as? [String: String] {
            table = dict
        }
        tables[language] = table
        return table
    }
}

@MainActor
final class SettingsSearchRouter: ObservableObject {
    static let shared = SettingsSearchRouter()

    @Published private(set) var highlightedTitles: Set<String> = []

    @Published private(set) var pendingDrawer: LyricsSurface?

    private var clearHighlight: DispatchWorkItem?
    private var clearDrawer: DispatchWorkItem?

    static let highlightDuration: TimeInterval = 1.8

    func reveal(_ hit: SettingsSearchHit) {
        clearHighlight?.cancel()
        clearDrawer?.cancel()
        pendingDrawer = hit.entry.drawer
        highlightedTitles = hit.highlightTitles

        let highlightWork = DispatchWorkItem { [weak self] in self?.highlightedTitles = [] }
        clearHighlight = highlightWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDuration, execute: highlightWork)

        let drawerWork = DispatchWorkItem { [weak self] in self?.pendingDrawer = nil }
        clearDrawer = drawerWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: drawerWork)
    }

    func consumeDrawer(_ surface: LyricsSurface) {
        guard pendingDrawer == surface else { return }
        pendingDrawer = nil
        clearDrawer?.cancel()
    }
}

private struct SettingsSearchHighlightedTitlesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

private struct SettingsSearchPendingDrawerKey: EnvironmentKey {
    static let defaultValue: LyricsSurface? = nil
}

extension EnvironmentValues {

    var settingsSearchHighlightedTitles: Set<String> {
        get { self[SettingsSearchHighlightedTitlesKey.self] }
        set { self[SettingsSearchHighlightedTitlesKey.self] = newValue }
    }

    var settingsSearchPendingDrawer: LyricsSurface? {
        get { self[SettingsSearchPendingDrawerKey.self] }
        set { self[SettingsSearchPendingDrawerKey.self] = newValue }
    }
}

struct SettingsSearchHighlight: ViewModifier {
    let title: String?
    @Environment(\.settingsSearchHighlightedTitles) private var highlightedTitles

    private var isHighlighted: Bool {
        guard let title, !title.isEmpty else { return false }
        return highlightedTitles.contains(title)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                    SettingsRevealInScrollView()
                }
            }

            .animation(.easeOut(duration: 0.3), value: isHighlighted)
    }
}

extension View {
    func settingsSearchHighlight(title: String?) -> some View {
        modifier(SettingsSearchHighlight(title: title))
    }
}

private struct SettingsRevealInScrollView: NSViewRepresentable {
    func makeNSView(context: Context) -> RevealView { RevealView() }
    func updateNSView(_ nsView: RevealView, context: Context) { nsView.scheduleReveal() }

    final class RevealView: NSView {
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReveal()
        }

        func scheduleReveal() {
            guard !scheduled, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in self?.reveal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.reveal() }
        }

        private func reveal() {
            guard window != nil, enclosingScrollView != nil else { return }

            scrollToVisible(bounds.insetBy(dx: 0, dy: -72))
        }
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.t("搜索"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand {
                    if text.isEmpty { focused.wrappedValue = false } else { text = "" }
                }
                .onAppear {

                    DispatchQueue.main.async { focused.wrappedValue = false }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 8)

        .frame(height: 26)

        .settingsSearchFieldBackground()
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {

            Button("") { focused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

struct SettingsSearchResultRow: View {
    let hit: SettingsSearchHit
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hit.breadcrumb)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hit.title)
        .accessibilityValue(hit.breadcrumb)
    }
}
