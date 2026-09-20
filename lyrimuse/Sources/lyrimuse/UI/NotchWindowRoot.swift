import LyrimuseCore
import SwiftUI

struct NotchWindowRoot: View {

    static let vanishDuration: TimeInterval = 0.2

    static let vanishSettleDelay: TimeInterval = 0.25
    @ObservedObject var controller: NotchLyricsWindowController

    @State private var hoveringCard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardAnimation: Animation? {
        if reduceMotion { return nil }
        if controller.isCollapsed {
            return .spring(response: 0.45, dampingFraction: 1.0)
        }
        if controller.isExpanded {
            return .interactiveSpring(response: 0.38, dampingFraction: 0.8)
        }
        if wasExpanded {
            return .spring(response: 0.38, dampingFraction: 0.9)
        }
        return .spring(response: 0.42, dampingFraction: 0.8)
    }

    @State private var wasExpanded = false

    private var cardWidth: CGFloat {
        if controller.isCollapsed {
            return min(controller.steadyCardWidth,
                       controller.notchWidth + 2 * NotchMetrics.collapsedEarWidth + 20)
        }
        return controller.isExpanded ? controller.expandedCardWidth : controller.steadyCardWidth
    }

    private var cardHeight: CGFloat { controller.cardHeight }

    private var vanishAnimation: Animation? {
        if reduceMotion { return nil }
        return controller.isVanished ? .easeIn(duration: Self.vanishDuration) : nil
    }

    private var revealStartWidth: CGFloat {
        NotchReveal.startWidthFraction(notchWidth: controller.notchWidth, cardWidth: cardWidth)
    }
    private var revealStartHeight: CGFloat {
        NotchReveal.startHeightFraction(topRowHeight: controller.contentTopInset, cardHeight: cardHeight)
    }

    var body: some View {

        NotchLyricsView(controller: controller, prompt: .shared)

            .environment(\.notchHostClipsCard, true)
            .frame(width: cardWidth, height: cardHeight)

            .keyframeAnimator(initialValue: NotchRevealState.settled,
                              trigger: reduceMotion ? 0 : controller.revealGeneration) { card, state in
                card
                    .environment(\.notchRevealContentOpacity, state.contentOpacity)
                    .clipShape(NotchRevealShape(widthFraction: state.widthFraction,
                                                heightFraction: state.heightFraction))
            } keyframes: { _ in
                KeyframeTrack(\.widthFraction) {
                    MoveKeyframe(revealStartWidth)
                    SpringKeyframe(1, duration: NotchReveal.widthDuration,
                                   spring: Spring(response: 0.22, dampingRatio: 0.9))
                }
                KeyframeTrack(\.heightFraction) {
                    MoveKeyframe(revealStartHeight)
                    LinearKeyframe(revealStartHeight, duration: NotchReveal.heightDelay)
                    SpringKeyframe(1, duration: NotchReveal.heightDuration,
                                   spring: Spring(response: 0.26, dampingRatio: 0.85))
                }
                KeyframeTrack(\.contentOpacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: NotchReveal.contentDelay)
                    CubicKeyframe(1, duration: NotchReveal.contentDuration)
                }
            }

            .scaleEffect(controller.isVanished ? 0.001 : 1, anchor: .top)
            .opacity(controller.isVanished ? 0 : 1)

            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {

                case .active(let point):
                    updateHover(inside: NotchHoverHit.isInside(point: point,
                                                               cardWidth: cardWidth,
                                                               cardHeight: cardHeight))
                case .ended: updateHover(inside: false)
                }
            }

            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            .animation(cardAnimation, value: cardHeight)
            .animation(cardAnimation, value: cardWidth)

            .animation(cardAnimation, value: controller.isCollapsed)
            .animation(vanishAnimation, value: controller.isVanished)
            .onChange(of: controller.isExpanded) { _, expanded in wasExpanded = expanded }
    }

    private func updateHover(inside: Bool) {

        let changed = inside != hoveringCard
        hoveringCard = inside
        if changed { controller.setExpandedFromWindow(inside) }
    }
}
