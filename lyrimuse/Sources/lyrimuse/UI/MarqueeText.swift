import LyrimuseCore
import SwiftUI

let marqueePixelsPerSecond: Double = 24
let marqueeHoldDuration: Double = 1.1

struct MarqueeText<Content: View>: View {
    let id: AnyHashable

    var restingAlignment: Alignment = .leading

    var edgeFadeWidth: CGFloat = 0
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    @State private var generation: Int = 0
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outerProxy in
            content()
                .fixedSize(horizontal: true, vertical: false)

                .background(
                    GeometryReader { innerProxy in
                        Color.clear
                            .onAppear { apply(content: innerProxy.size.width, container: outerProxy.size.width) }
                            .onChange(of: innerProxy.size.width) { _, w in
                                apply(content: w, container: outerProxy.size.width)
                            }
                    }
                )
                .offset(x: -offset)

                .animation(nil, value: generation)

                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isOverflowing ? .leading : restingAlignment)

                .onChange(of: outerProxy.size.width) { _, w in
                    apply(content: contentWidth, container: w)
                }
                .onChange(of: id) {

                    restart()
                }
        }
        .clipped()

        .mask(fadeMask)
        .onDisappear { scrollTask?.cancel() }
    }

    private var overflow: CGFloat {
        MarqueeMath.overflow(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    private var isOverflowing: Bool {
        MarqueeMath.isOverflowing(contentWidth: contentWidth, containerWidth: containerWidth)
    }

    private var fadeWidth: CGFloat {
        MarqueeMath.trailingFadeWidth(configured: edgeFadeWidth,
                                      contentWidth: contentWidth,
                                      containerWidth: containerWidth,
                                      offset: offset)
    }

    private var fadeMask: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fadeWidth)
        }
    }

    private func apply(content: CGFloat, container: CGFloat) {
        guard content != contentWidth || container != containerWidth else { return }
        let contentChanged = content != contentWidth
        let wasOverflowing = isOverflowing

        let midScroll = offset != 0
        contentWidth = content
        containerWidth = container

        if !contentChanged, wasOverflowing == isOverflowing, !midScroll { return }
        restart()
    }

    private func restart() {
        scrollTask?.cancel()
        scrollTask = nil

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            generation &+= 1
        }
        guard isOverflowing else { return }
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }

                let distance = overflow
                guard distance > 0 else { return }
                let travelDuration = Double(distance) / marqueePixelsPerSecond
                withAnimation(.linear(duration: travelDuration)) { offset = distance }
                try? await Task.sleep(nanoseconds: UInt64(travelDuration * 1_000_000_000) + UInt64(marqueeHoldDuration * 1_000_000_000))
                if Task.isCancelled { return }

                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { offset = 0 }
                try? await Task.sleep(nanoseconds: UInt64(marqueeHoldDuration * 1_000_000_000))
            }
        }
    }
}
