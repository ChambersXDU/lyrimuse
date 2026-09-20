import AppKit
import SwiftUI

@MainActor
struct FontFamilyPicker: View {

    @Binding var selection: String

    @State private var showingList = false
    @State private var query = ""

    private static let families: [String] = NSFontManager.shared.availableFontFamilies

        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    private static let localizedNames: [String: String] = {
        var map: [String: String] = [:]
        for family in families {

            let localized = NSFontManager.shared.localizedName(forFamily: family, face: nil)
            if localized != family { map[family] = localized }
        }
        return map
    }()

    private var filtered: [String] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return Self.families }
        return Self.families.filter { family in
            family.localizedCaseInsensitiveContains(keyword)
                || (Self.localizedNames[family]?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    static func displayName(for family: String) -> String {
        family.isEmpty ? L10n.t("系统字体") : family
    }

    private var currentLabel: String { Self.displayName(for: selection) }

    var body: some View {
        Button {
            query = ""
            showingList = true
        } label: {
            HStack(spacing: 5) {

                Text(currentLabel)
                    .font(selection.isEmpty ? .system(size: 13) : .custom(selection, size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 190, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showingList, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(L10n.t("搜索字体"), text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        row(family: "", label: L10n.t("系统字体"))
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(filtered, id: \.self) { family in
                        row(family: family, label: family)
                    }
                    if filtered.isEmpty {
                        Text(L10n.t("没有匹配的字体"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                }
            }
        }
        .frame(width: 260, height: 320)
    }

    private func row(family: String, label: String) -> some View {
        Button {
            selection = family
            showingList = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(family == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 0) {

                    Text(label)
                        .font(family.isEmpty ? .system(size: 13) : .custom(family, size: 13))
                        .lineLimit(1)
                    if let localized = Self.localizedNames[family] {
                        Text(localized)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
