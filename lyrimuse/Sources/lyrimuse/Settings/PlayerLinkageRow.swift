import LyrimuseCore
import SwiftUI

struct PlayerLinkageRow: View {
    let icon: String
    let title: String

    let candidates: [PlaybackPlayer]
    let chosen: Set<PlaybackPlayer>
    let onChange: (Set<PlaybackPlayer>) -> Void

    var body: some View {
        SettingsRow(icon: icon, title: title) {
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

enum PlayerChipMetrics {
    static let iconSize: CGFloat = 22
    static let spacing: CGFloat = 6
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
