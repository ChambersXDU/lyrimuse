import LyrimuseCore
import SwiftUI

enum LyricsLibraryStats {

    typealias Kind = LyricsKind

    static func kind(
        hasWordTiming: Bool, hasLyrics: Bool, hasPlainTextFallback: Bool, isInstrumental: Bool
    ) -> Kind {
        Kind.classify(
            hasWordTiming: hasWordTiming, hasLyrics: hasLyrics,
            hasPlainTextFallback: hasPlainTextFallback, isInstrumental: isInstrumental)
    }

    struct Counts: Equatable {
        var total = 0
        var byKind: [String: Int] = [:]

        var communityTranslation = 0

        var machineTranslation = 0

        var bundledRomanization = 0

        func count(_ kind: Kind) -> Int { byKind[kind.rawValue] ?? 0 }
    }

    static func counts(_ summaries: [EnrichCacheStore.Summary]) -> Counts {
        var counts = Counts()
        for summary in summaries {

            guard !summary.isSearching else { continue }
            counts.total += 1
            let kind = kind(
                hasWordTiming: summary.hasWordTiming,
                hasLyrics: summary.hasLyrics,
                hasPlainTextFallback: summary.hasPlainTextFallback,
                isInstrumental: summary.isInstrumental)
            counts.byKind[kind.rawValue, default: 0] += 1

            switch LyricsTranslationSource.classify(
                hasTranslation: summary.hasTranslation, trSource: summary.lyricsTrSource) {
            case .community: counts.communityTranslation += 1
            case .machine: counts.machineTranslation += 1
            case .none: break
            }
            if summary.hasRomanization { counts.bundledRomanization += 1 }
        }
        return counts
    }
}

extension LyricsKind {
    var label: String {
        switch self {
        case .wordByWord: return L10n.t("逐字")
        case .lineByLine: return L10n.t("逐行")
        case .plainText: return L10n.t("纯文本")
        case .instrumental: return L10n.t("纯音乐")
        case .none: return L10n.t("暂无")
        }
    }

    var tint: Color {
        self == .none ? .orange : .primary
    }

    var barColor: Color {
        switch self {
        case .wordByWord: return .accentColor
        case .lineByLine: return .accentColor.opacity(0.55)
        case .plainText: return .accentColor.opacity(0.28)
        case .instrumental: return Color.secondary.opacity(0.35)
        case .none: return .orange
        }
    }
}

struct LyricsLibrarySizeLabel: View {
    @ObservedObject private var store = EnrichCacheStore.shared

    var body: some View {

        if store.totalSizeBytes > 0 {
            Text(EnrichCacheStore.byteText(store.totalSizeBytes))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(String(
                    format: L10n.t("占用空间：%@"),
                    EnrichCacheStore.byteText(store.totalSizeBytes)))
        }
    }
}

struct LyricsLibraryStatsPanel: View {
    @ObservedObject private var store = EnrichCacheStore.shared

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static func format(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        let counts = LyricsLibraryStats.counts(store.summaries)

        VStack(spacing: 0) {
            if store.summaries.isEmpty && store.isLoading {
                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在统计歌词库…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if counts.total == 0 {

                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    Text(L10n.t("还没有缓存任何歌词。放一首歌，Lyrimuse 会自动搜好存在这里"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsRawRow(insetToText: true, icon: "music.note.list") {
                    statsBlock(counts)
                }
                CardDivider()

                SettingsSubRow(title: L10n.t("译文")) {
                    Text(String(
                        format: L10n.t("%1$@ 首源自带 · %2$@ 首机翻"),
                        Self.format(counts.communityTranslation),
                        Self.format(counts.machineTranslation)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                CardDivider()

                SettingsSubRow(title: L10n.t("已缓存罗马音")) {
                    Text(String(format: L10n.t("%@ 首歌"), Self.format(counts.bundledRomanization)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }

        .task {
            await store.reload(onlyIfChanged: true)
        }
    }

    private func statsBlock(_ counts: LyricsLibraryStats.Counts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Self.totalText(counts.total)
                    .accessibilityLabel(String(format: L10n.t("共 %@ 首"), Self.format(counts.total)))
                Spacer(minLength: 12)
                LyricsLibrarySizeLabel()
            }
            SettingsProportionBar(segments: LyricsLibraryStats.Kind.allCases.map { kind in
                .init(id: kind.rawValue, value: counts.count(kind), color: kind.barColor)
            })

            HStack(spacing: 14) {
                ForEach(LyricsLibraryStats.Kind.allCases.filter { $0 != .none }, id: \.self) { kind in
                    legendItem(kind, value: counts.count(kind))
                }
            }
            noneRow(counts)
        }
    }

    private static func totalText(_ count: Int) -> Text {
        let number = Text(format(count))
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
        let parts = L10n.t("共 %@ 首").components(separatedBy: "%@")
        guard parts.count == 2 else { return number }
        let body = Font.system(size: 13)
        return Text(parts[0]).font(body) + number + Text(parts[1]).font(body)
    }

    private func legendItem(_ kind: LyricsLibraryStats.Kind, value: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.barColor)
                .frame(width: 7, height: 7)
            Text(kind.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Self.format(value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? kind.tint : Color.primary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label)：\(Self.format(value))")
    }

    private func noneRow(_ counts: LyricsLibraryStats.Counts) -> some View {
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                legendItem(.none, value: counts.count(.none))
            }
            Spacer(minLength: 12)
        }

        .settingsGlassButtons()
    }
}
