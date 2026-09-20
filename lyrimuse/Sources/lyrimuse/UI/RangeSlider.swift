import LyrimuseCore
import SwiftUI

struct RangeSlider: View {
    typealias Thumb = NotchWidthRangeDrag.Thumb

    let lower: Double
    let upper: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    let lowerLabel: String
    let upperLabel: String
    let valueText: (Double) -> String
    let onChange: (_ lower: Double, _ upper: Double) -> Void
    let onEditingChanged: (Thumb?) -> Void

    @State private var activeThumb: Thumb?

    private static let thumbSize: CGFloat = 12
    private static let activeThumbSize: CGFloat = 14
    private static let trackHeight: CGFloat = 4

    private var adjustableStep: Double { max(step, 1) * 5 }

    var body: some View {
        GeometryReader { geo in

            let travel = max(1, geo.size.width - Self.thumbSize)
            let lowerX = x(for: lower, travel: travel)
            let upperX = x(for: upper, travel: travel)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.28))
                    .frame(height: Self.trackHeight)
                    .padding(.horizontal, Self.thumbSize / 2)

                Capsule()
                    .fill(tint)
                    .frame(width: max(0, upperX - lowerX), height: Self.trackHeight)
                    .offset(x: lowerX)
                    .padding(.horizontal, Self.thumbSize / 2)
                thumb(.steady, centerX: lowerX + Self.thumbSize / 2)
                thumb(.expanded, centerX: upperX + Self.thumbSize / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        drag(gesture, travel: travel,
                             lowerCenterX: lowerX + Self.thumbSize / 2,
                             upperCenterX: upperX + Self.thumbSize / 2)
                    }
                    .onEnded { _ in
                        guard activeThumb != nil else { return }
                        activeThumb = nil
                        onEditingChanged(nil)
                    }
            )
        }
        .frame(height: Self.activeThumbSize + 4)
        .accessibilityElement(children: .contain)
    }

    private func x(for value: Double, travel: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (value - range.lowerBound) / span
        return CGFloat(min(max(fraction, 0), 1)) * travel
    }

    private func value(atCenterX x: CGFloat, travel: CGFloat) -> Double {
        let fraction = Double((x - Self.thumbSize / 2) / travel)
        return range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
    }

    private func thumb(_ which: Thumb, centerX: CGFloat) -> some View {
        let active = activeThumb == which
        let size = active ? Self.activeThumbSize : Self.thumbSize
        return Circle()
            .fill(tint)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.1), value: active)
            .accessibilityElement()
            .accessibilityLabel(which == .steady ? lowerLabel : upperLabel)
            .accessibilityValue(valueText(which == .steady ? lower : upper))
            .accessibilityAdjustableAction { direction in adjust(which, direction: direction) }
            .position(x: centerX, y: Self.activeThumbSize / 2 + 2)
    }

    private func drag(_ gesture: DragGesture.Value, travel: CGFloat,
                      lowerCenterX: CGFloat, upperCenterX: CGFloat) {
        if activeThumb == nil {

            guard let thumb = NotchWidthRangeDrag.thumb(
                pressX: gesture.startLocation.x, steadyX: lowerCenterX, expandedX: upperCenterX,
                dx: gesture.translation.width) else { return }
            activeThumb = thumb
            onEditingChanged(thumb)
        }
        guard let thumb = activeThumb else { return }
        let raw = value(atCenterX: gesture.location.x, travel: travel)
        let snapped = SteppedSlider.snap(raw, in: range, step: step)
        let pair = NotchWidthRangeDrag.dragging(thumb, to: snapped, steady: lower, expanded: upper)
        onChange(pair.steady, pair.expanded)
    }

    private func adjust(_ thumb: Thumb, direction: AccessibilityAdjustmentDirection) {
        let current = thumb == .steady ? lower : upper
        let delta = direction == .increment ? adjustableStep : -adjustableStep
        let snapped = SteppedSlider.snap(current + delta, in: range, step: step)
        let pair = NotchWidthRangeDrag.dragging(thumb, to: snapped, steady: lower, expanded: upper)
        onEditingChanged(thumb)
        onChange(pair.steady, pair.expanded)
        onEditingChanged(nil)
    }
}
