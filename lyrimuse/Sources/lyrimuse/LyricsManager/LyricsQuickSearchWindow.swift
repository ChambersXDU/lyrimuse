import SwiftUI
import LyrimuseCore

struct LyricsQuickSearchWindow: View {
    @State private var context: Context?

    private struct Context {
        let artist: String
        let title: String
        let album: String

        let key: String
        let currentSource: String?

        let currentFingerprint: String?
        let durationSecs: Double
    }

    var body: some View {
        Group {
            if let context {
                LyricsSearchSheet(
                    artist: context.artist, title: context.title, album: context.album,
                    currentSource: context.currentSource, currentFingerprint: context.currentFingerprint,
                    durationSecs: context.durationSecs, keepsOpenAfterApply: true
                ) { candidate in

                    await EnrichCacheStore.shared.reload(onlyIfChanged: true)
                    let saved: Bool
                    if candidate.isPlainTextOnly {

                        saved = await EnrichCacheStore.shared.savePlainTextEdit(
                            key: context.key, plainLyrics: candidate.lyrics, source: candidate.source)
                    } else {

                        saved = await EnrichCacheStore.shared.saveEdit(
                            key: context.key,
                            lyrics: candidate.lyrics, tr: candidate.lyricsTr,
                            roma: candidate.lyricsRoma, yrc: candidate.lyricsYRC,
                            source: candidate.source, markManual: AppSettings.shared.manualPickLocksLyrics,
                            sourceChoice: "", fromManualPick: true)
                    }
                    PlaybackCoordinator.shared.refreshLyricsForCurrentTrack()
                    return saved
                }
            } else {

                ProgressView().frame(minWidth: 720, minHeight: 480)
            }
        }
        .task { loadContext() }

        .onReceive(AppActions.shared.quickSearchRefreshRequests) { loadContext() }
    }

    private func loadContext() {
        let p = PlaybackCoordinator.shared
        let artist = p.artist, title = p.title, album = p.album
        let durationSecs = Double(p.currentDurationMs ?? 0) / 1000
        let key = EnrichCacheReader.resolvedKey(artist: artist, title: title, album: album)
            ?? EnrichCacheKeys.normalizedKey(artist: artist, title: title, album: album)
        let source = EnrichCacheReader.sourceInfo(artist: artist, title: title, album: album)?.lyricsSource

        let lyrics = EnrichCacheReader.lookup(artist: artist, title: title, album: album)?.lyrics ?? ""
        let fingerprint = lyrics.isEmpty ? nil : ManualPickLock.fingerprint(lyrics: lyrics)

        context = Context(
            artist: artist, title: EnrichCacheKeys.normalizedTitle(title), album: album,
            key: key, currentSource: source, currentFingerprint: fingerprint, durationSecs: durationSecs)
    }
}
