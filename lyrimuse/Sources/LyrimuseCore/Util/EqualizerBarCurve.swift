import Foundation

public enum EqualizerBarCurve {

    public static func contrast(_ unit: Double) -> Double {
        let u = min(1, max(0, unit))
        return u * u * (3 - 2 * u)
    }

    public static func level(unit: Double, amplitude: Double) -> Double {
        min(1, contrast(unit) * max(0, amplitude))
    }
}
