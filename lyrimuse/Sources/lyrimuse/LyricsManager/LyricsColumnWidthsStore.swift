import Foundation
import LyrimuseCore

@MainActor
final class LyricsColumnWidthsStore: ObservableObject {
    static let shared = LyricsColumnWidthsStore()

    private enum Keys {

        static let artist = "np:lyricsManagerColArtist"
        static let album = "np:lyricsManagerColAlbum"
        static let source = "np:lyricsManagerColSource"
    }

    private let defaults = UserDefaults.standard

    @Published var widths: LyricsColumnWidths {
        didSet {
            guard widths != oldValue, !isDragging else { return }
            persistWidths()
        }
    }

    private var isDragging = false

    func beginDragging() { isDragging = true }

    func endDragging() {
        isDragging = false
        persistWidths()
    }

    private func persistWidths() {
        defaults.set(Double(widths.artist), forKey: Keys.artist)
        defaults.set(Double(widths.album), forKey: Keys.album)
        defaults.set(Double(widths.source), forKey: Keys.source)
    }

    private init() {

        if defaults.object(forKey: Keys.artist) == nil
            || defaults.object(forKey: Keys.album) == nil
            || defaults.object(forKey: Keys.source) == nil {
            widths = LyricsColumnWidths.defaults
        } else {
            widths = LyricsColumnWidths.sanitized(LyricsColumnWidths(
                artist: CGFloat(defaults.double(forKey: Keys.artist)),
                album: CGFloat(defaults.double(forKey: Keys.album)),
                source: CGFloat(defaults.double(forKey: Keys.source))
            ))
        }
    }

    func reset() {

        isDragging = false
        widths = LyricsColumnWidths.defaults
    }
}
