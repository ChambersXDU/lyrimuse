import AppKit
import SwiftUI

struct HelpButton: View {
    let text: String
    var docTitle: String? = nil
    var docURL: URL? = nil

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout)
                if let docTitle, let docURL {

                    Button(docTitle) { NSWorkspace.shared.open(docURL) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}

struct QuickHelpLabel<Content: View>: View {
    let text: String
    @ViewBuilder let content: () -> Content

    private static var hoverDelay: Duration { .milliseconds(500) }

    private static var closeGrace: Duration { .milliseconds(150) }

    @State private var isPresented = false

    @State private var pinnedByClick = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 3) {
            content()
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.tertiary)

                .contentShape(Rectangle())
                .onTapGesture {
                    hoverTask?.cancel()
                    pinnedByClick = true
                    isPresented = true
                }
        }

        .onHover { inside in
            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: inside ? Self.hoverDelay : Self.closeGrace)
                guard !Task.isCancelled else { return }
                if inside {
                    isPresented = true
                } else if !pinnedByClick {
                    isPresented = false
                }
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)

                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280, alignment: .leading)
        }

        .onChange(of: isPresented) { _, shown in
            if !shown { pinnedByClick = false }
        }

        .onDisappear { hoverTask?.cancel() }
    }
}
