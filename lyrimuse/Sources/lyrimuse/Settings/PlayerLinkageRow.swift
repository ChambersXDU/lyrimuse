import LyrimuseCore
import SwiftUI

struct PlayerLinkageRow: View {
    let icon: String
    let title: String
    var help: String?

    let candidates: [PlaybackPlayer]
    let chosen: Set<PlaybackPlayer>
    let onChange: (Set<PlaybackPlayer>) -> Void

    private var summary: String {
        let picked = candidates.filter { chosen.contains($0) }
        return picked.isEmpty ? L10n.t("未勾选，此项关闭") : picked.map(\.displayName).joined(separator: "、")
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: summary, help: help) {
            PlayerLinkageChips(candidates: candidates, chosen: chosen) { player in
                var next = chosen
                if next.contains(player) { next.remove(player) } else { next.insert(player) }
                onChange(next)
            }
        }
    }
}

private struct PlayerLinkageChips: View {
    let candidates: [PlaybackPlayer]
    let chosen: Set<PlaybackPlayer>
    let toggle: (PlaybackPlayer) -> Void

    var body: some View {
        HStack(spacing: PlayerChipMetrics.spacing) {
            ForEach(candidates) { player in
                PlayerChip(selected: chosen.contains(player), label: player.displayName) {
                    toggle(player)
                } icon: {
                    PlayerIconView(player: player, size: PlayerChipMetrics.iconSize)
                }
            }
        }

        .fixedSize()
    }
}

struct PlayerBundleChoice: Identifiable, Equatable {

    let id: String
    let name: String
    let player: PlaybackPlayer?
}

struct PlayerBundleChipsRow: View {
    let icon: String
    let title: String
    var help: String?
    let choices: [PlayerBundleChoice]

    let excluded: Set<String>

    let onToggle: (String, Bool) -> Void

    private var summary: String {
        let off = choices.filter { excluded.contains($0.id) }
        if off.isEmpty { return L10n.t("全部勾选") }
        if off.count == choices.count { return L10n.t("全部不 scrobble") }
        return String(format: L10n.t("不 scrobble：%@"), off.map(\.name).joined(separator: "、"))
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: summary, help: help) {
            PlayerChipFlow(spacing: PlayerChipMetrics.spacing) {
                ForEach(choices) { choice in
                    let selected = !excluded.contains(choice.id)
                    PlayerChip(selected: selected, label: choice.name) {
                        onToggle(choice.id, !selected)
                    } icon: {
                        if let player = choice.player {
                            PlayerIconView(player: player, size: PlayerChipMetrics.iconSize)
                        } else {
                            TrustedPlayerIconView(bundleID: choice.id, size: PlayerChipMetrics.iconSize)
                        }
                    }
                }
            }

            .frame(maxWidth: PlayerChipMetrics.flowMaxWidth, alignment: .trailing)
        }
    }
}

private struct TrustedPlayerIconView: View {
    let bundleID: String
    var size: CGFloat
    @State private var resolved: NSImage?

    var body: some View {
        Group {
            if let resolved {
                Image(nsImage: resolved).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.secondary,
                                in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            }
        }
        .onAppear { if resolved == nil { resolved = AppIconResolver.icon(forBundleID: bundleID) } }
    }
}

enum PlayerChipMetrics {
    static let iconSize: CGFloat = 22
    static let spacing: CGFloat = 6
    static let flowMaxWidth: CGFloat = 320
}

private struct PlayerChip<Icon: View>: View {
    let selected: Bool
    let label: String
    let toggle: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: toggle) {
            icon()
                .saturation(selected ? 1 : 0)
                .opacity(selected ? 1 : 0.4)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(label)

        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlayerChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = ChipFlowGeometry.rows(widths: sizes.map(\.width), spacing: spacing,
                                         limit: proposal.width ?? .greatestFiniteMagnitude)
        return ChipFlowGeometry.size(rows: rows, rowHeight: sizes.map(\.height).max() ?? 0, spacing: spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowHeight = sizes.map(\.height).max() ?? 0
        var y = bounds.minY
        for row in ChipFlowGeometry.rows(widths: sizes.map(\.width), spacing: spacing, limit: bounds.width) {

            var x = bounds.maxX - row.width
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
