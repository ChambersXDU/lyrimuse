import Foundation

public enum VocalEnvelope {

    public static let onsetBoost = 0.25

    public static let attackMs = 80.0

    public static let releaseMs = 250.0

    public static let gapFloor = 0.6

    public static let idleAmplitude = 1.0

    public static func amplitude(atMs posMs: Int, words: [SyncedLyricWord]) -> Double {
        guard !words.isEmpty else { return idleAmplitude }
        var lastEndBefore: Int? = nil
        for w in words {
            let end = w.startMs + max(0, w.durationMs)
            if posMs >= w.startMs && posMs < end {
                let sinceOnset = Double(posMs - w.startMs)
                return 1 + onsetBoost * exp(-sinceOnset / attackMs)
            }
            if end <= posMs {
                lastEndBefore = max(lastEndBefore ?? end, end)
            }
        }
        guard let lastEnd = lastEndBefore else { return gapFloor }
        let sinceRelease = Double(posMs - lastEnd)
        return gapFloor + (1 - gapFloor) * exp(-sinceRelease / releaseMs)
    }
}
