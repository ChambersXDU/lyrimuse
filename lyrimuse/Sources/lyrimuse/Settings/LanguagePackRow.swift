import SwiftUI
import os

#if canImport(Translation)
    import Translation
#endif

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "language-packs")

@available(macOS 26.0, *)
@MainActor
final class LanguagePackStatusStore: ObservableObject {
    static let shared = LanguagePackStatusStore()

    @Published private(set) var codes: [String] = []
    @Published private(set) var statuses: [String: LanguageAvailability.Status] = [:]
    @Published private(set) var hasLoaded = false

    private var inFlight: Task<Void, Never>?

    private static let preferred = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    private static func canonical(_ lang: Locale.Language) -> String? {
        guard let base = lang.languageCode?.identifier else { return nil }
        if base == "zh", let script = lang.script?.identifier { return "zh-\(script)" }
        return base
    }

    static func displayName(_ code: String) -> String {
        L10n.locale.localizedString(forIdentifier: code) ?? code
    }

    func refresh(target: Locale.Language) {

        inFlight?.cancel()
        inFlight = Task { [weak self] in
            let availability = LanguageAvailability()
            let targetCode = Self.canonical(target)
            var seen = Set<String>()
            var list: [String] = []

            for lang in await availability.supportedLanguages {
                guard let code = Self.canonical(lang) else { continue }

                guard code != targetCode else { continue }
                guard seen.insert(code).inserted else { continue }
                list.append(code)
            }
            list.sort { a, b in
                let ia = Self.preferred.firstIndex(of: a) ?? Int.max
                let ib = Self.preferred.firstIndex(of: b) ?? Int.max
                if ia != ib { return ia < ib }

                return Self.displayName(a).compare(
                    Self.displayName(b), options: [], range: nil, locale: L10n.locale
                ) == .orderedAscending
            }

            var next: [String: LanguageAvailability.Status] = [:]
            for code in list {
                if Task.isCancelled { return }
                next[code] = await availability.status(
                    from: Locale.Language(identifier: code), to: target)
            }

            if !list.isEmpty, !next.values.contains(.installed) {
                logger.notice("language packs: all zero, re-verifying in 5s (translationd cold-start suspected)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                var second: [String: LanguageAvailability.Status] = [:]
                for code in list {
                    if Task.isCancelled { return }
                    second[code] = await availability.status(
                        from: Locale.Language(identifier: code), to: target)
                }
                next = second
            }

            list.removeAll { next[$0] == .unsupported }
            next = next.filter { $0.value != .unsupported }
            guard !Task.isCancelled else { return }

            let installed = next.filter { $0.value == .installed }.map(\.key).sorted()
            logger.notice("language packs: target=\(Self.canonical(target) ?? "?", privacy: .public) listed=\(list.count, privacy: .public) installed=\(installed.count, privacy: .public) \(installed.joined(separator: ","), privacy: .public)")
            self?.codes = list
            self?.statuses = next
            self?.hasLoaded = true
        }
    }
}

@available(macOS 26.0, *)
struct LanguagePackRow: View {
    @ObservedObject private var features = FeatureSettingsStore.shared
    @ObservedObject private var store = LanguagePackStatusStore.shared
    @State private var pending: TranslationSession.Configuration?
    @State private var downloading: String?
    @State private var isExpanded = false

    @State private var hoveredCode: String?

    @State private var downloadNonce = 0

    private static let columns = 3

    private var target: Locale.Language {
        let raw = features.lyricsTranslationLanguage.rawValue.lowercased()
        switch raw {
        case "auto", "":
            let system = Locale.current.language
            return system.languageCode?.identifier == "zh"
                ? Locale.Language(identifier: "zh-Hans") : system
        case "zh", "zh-cn", "zh-hans": return Locale.Language(identifier: "zh-Hans")
        case "zh-tw", "zh-hant": return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: raw)
        }
    }

    private var installedCount: Int {
        store.statuses.values.filter { $0 == .installed }.count
    }

    var body: some View {

        VStack(spacing: 0) {
            SettingsRow(
                icon: "arrow.down.circle",
                title: L10n.t("翻译语言包"),
                help: L10n.t("只统计能翻成当前译文语言的语言；译文语言自己和同一语系的语言不计，所以数字可能比「系统设置」里的少。语言包由 macOS 管理，翻译在本机完成")
            ) {
                HStack(spacing: 10) {

                    Text(summaryText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(isExpanded ? L10n.t("收起") : L10n.t("管理…")) {
                        withAnimation(.settingsCardReveal) { isExpanded.toggle() }
                    }
                    .controlSize(.small)
                    .accessibilityValue(isExpanded ? L10n.t("已展开") : L10n.t("已折叠"))
                }
            }
            if isExpanded {
                CardDivider()
                SettingsRawRow(insetToText: true) { packGrid }
                SettingsNote {
                    Text(L10n.t("要删除已下载的语言包，请到「系统设置 › 通用 › 语言与地区 › 翻译语言」"))
                    Button(L10n.t("打开系统设置")) {

                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }

        .task(id: target.maximalIdentifier) {

            downloading = nil
            pending = nil
            store.refresh(target: target)
        }

        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            store.refresh(target: target)
            if let code = downloading, store.statuses[code] == .installed {
                downloading = nil
                pending = nil
            }
        }

        .task(id: downloadNonce) {
            guard downloadNonce > 0, let code = downloading else { return }
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled else { return }
            if downloading == code, store.statuses[code] != .installed {
                logger.notice("language packs: download watchdog fired for \(code, privacy: .public), clearing stuck spinner")
                downloading = nil
                pending = nil
            }
        }

        .background {
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(pending) { session in

                    logger.notice("language packs: prepareTranslation start (nonce=\(downloadNonce, privacy: .public), for=\(downloading ?? "?", privacy: .public))")
                    try? await session.prepareTranslation()
                    await MainActor.run {
                        logger.notice("language packs: prepareTranslation done (for=\(downloading ?? "?", privacy: .public))")
                        downloading = nil
                        pending = nil
                        store.refresh(target: target)
                    }
                }
                .id(downloadNonce)
        }
    }

    private var summaryText: String {
        guard store.hasLoaded else { return L10n.t("检查中…") }
        return String(format: L10n.t("已下载 %@ / %@"), "\(installedCount)", "\(store.codes.count)")
    }

    private func requestDownload(_ code: String) {
        downloading = code
        pending = TranslationSession.Configuration(
            source: Locale.Language(identifier: code), target: target)

        downloadNonce += 1
    }

    private var packGrid: some View {
        let codes = store.codes
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: codes.count, by: Self.columns)), id: \.self) { start in
                GridRow {
                    ForEach(codes[start ..< min(start + Self.columns, codes.count)], id: \.self) { code in
                        packCell(code)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("翻译语言包"))
    }

    @ViewBuilder
    private func packCell(_ code: String) -> some View {
        let installed = store.statuses[code] == .installed
        let isDownloading = downloading == code
        let name = LanguagePackStatusStore.displayName(code)
        let label = HStack(spacing: 6) {
            Group {
                if isDownloading {
                    ProgressView().controlSize(.mini)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 15, height: 15)
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(installed ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)

        if installed {
            label
                .help(L10n.t("已下载"))
                .accessibilityLabel(String(format: L10n.t("%@，已下载"), name))
        } else {
            let hovered = hoveredCode == code
            Button {
                requestDownload(code)
            } label: {
                label
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hovered ? Color.secondary.opacity(0.12) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            .disabled(downloading != nil && !isDownloading)
            .help(isDownloading ? L10n.t("下载中…") : L10n.t("点击下载"))
            .onHover { hoveredCode = $0 ? code : (hoveredCode == code ? nil : hoveredCode) }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .accessibilityLabel(String(format: L10n.t("%@，点击下载"), name))
        }
    }
}
