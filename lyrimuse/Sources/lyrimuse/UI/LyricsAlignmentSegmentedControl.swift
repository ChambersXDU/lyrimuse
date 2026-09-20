import LyrimuseCore
import SwiftUI

@MainActor
struct LyricsAlignmentSegmentedControl: View {
    @Binding var selection: LyricsRestingAlignment

    let options: [LyricsRestingAlignment]

    static func label(for option: LyricsRestingAlignment) -> String {
        switch option {

        case .automatic: return L10n.t("自动")
        case .leading: return L10n.t("左对齐")
        case .center: return L10n.t("居中")
        case .trailing: return L10n.t("右对齐")
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(Self.label(for: option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(minWidth: 56)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .fixedSize()
    }
}
