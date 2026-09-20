import Foundation

public enum LyricsDecisionRow {

    public static func isInstrumentalMarker(instrumental: Bool?, score: Int) -> Bool {
        instrumental == true && score < 0
    }
}
