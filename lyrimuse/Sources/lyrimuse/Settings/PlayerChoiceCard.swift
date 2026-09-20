import AppKit
import LyrimuseCore
import SwiftUI

struct PlayerChoiceCard: View {
    let player: PlaybackPlayer
    let isSelected: Bool

    var isCoveredByAuto: Bool = false
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                PlayerIconView(player: player)
                Text(player.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            .choiceCardChrome(isSelected: isSelected, isCoveredByAuto: isCoveredByAuto)
        }
        .buttonStyle(.plain)

        .accessibilityAddTraits(isSelected ? .isSelected : [])

        .accessibilityValue(isCoveredByAuto ? L10n.t("由「自动识别」接管——取消「自动识别」后才只认你勾选的播放器") : "")

        .help(isCoveredByAuto ? L10n.t("由「自动识别」接管——取消「自动识别」后才只认你勾选的播放器") : "")
    }

}

struct PlayerIconView: View {
    let player: PlaybackPlayer
    var size: CGFloat = 26
    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: player.fallbackSymbolName)

                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(player.tintColor,
                                in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            }
        }
        .onAppear(perform: loadRealIconIfAvailable)
    }

    private func loadRealIconIfAvailable() {
        guard player != .auto else { return }
        if let installed = AppIconResolver.icon(forBundleID: player.bundleIdentifier) {
            resolvedIcon = installed
        } else if let name = player.bundledIconResourceName {
            resolvedIcon = AppIconResolver.icon(bundledResourceName: name)
        }
    }
}

private struct ChoiceCardChrome: ViewModifier {
    let isSelected: Bool

    var isCoveredByAuto: Bool = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )

            .overlay {
                if isCoveredByAuto, !isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }

            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)

                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(4)
                } else if isCoveredByAuto {

                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.65))
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(4)
                }
            }
    }
}

extension View {
    fileprivate func choiceCardChrome(isSelected: Bool, isCoveredByAuto: Bool = false) -> some View {
        modifier(ChoiceCardChrome(isSelected: isSelected, isCoveredByAuto: isCoveredByAuto))
    }
}

struct WebPlatformChoiceCard: View {
    let icon: NSImage?
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                } else {

                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
            }
            .choiceCardChrome(isSelected: isSelected)
        }
        .buttonStyle(.plain)

        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MorePlayersComingCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("•••")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
            Text(L10n.t("陆续支持中"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }
}
