import LyrimuseCore
import Foundation

@MainActor
func runSpotifyNativeTests() {

    do {
        let raw = "https://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"
        let url = SpotifyArtworkURL.parse(raw)
        expectEqual(url?.absoluteString, raw)
        expectEqual(SpotifyArtworkURL.parse(" \(raw)\n")?.absoluteString, raw)
        expectEqual(SpotifyArtworkURL.parse("https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e02b6d9a4fbb0bd49f0f034aead") != nil,
                    true)
        expectEqual(SpotifyArtworkURL.parse("missing value"), nil)
        expectEqual(SpotifyArtworkURL.parse(""), nil)
        expectEqual(SpotifyArtworkURL.parse("http://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil)
        expectEqual(SpotifyArtworkURL.parse("https://evil.example/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil)
        expectEqual(SpotifyArtworkURL.parse("https://i.scdn.co/other/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil)
        expectEqual(SpotifyArtworkURL.parse("https://i.scdn.co/image/ab67616d0000b273zz"), nil)
        expectEqual(SpotifyArtworkURL.parse("https://notspotifycdn.com/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"), nil)
        if let url {
            expectEqual(SpotifyArtworkURL.variant(url, .original)?.absoluteString,
                        "https://i.scdn.co/image/ab67616d000082c1bb54dde68cd23e2a268ae0f5")
            expectEqual(SpotifyArtworkURL.variant(url, .small)?.absoluteString,
                        "https://i.scdn.co/image/ab67616d00001e02bb54dde68cd23e2a268ae0f5")
            expectEqual(SpotifyArtworkURL.variant(url, .large)?.absoluteString, raw)
            expectEqual(SpotifyArtworkURL.downloadCandidates(for: url).map(\.absoluteString),
                        ["https://i.scdn.co/image/ab67616d000082c1bb54dde68cd23e2a268ae0f5", raw])
        }
        expectEqual(SpotifyArtworkURL.variant(URL(string: "https://p2.music.126.net/x.jpg")!, .original), nil)
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:track:0H5iEzn4EWoevLeB60ZJfj"), true)
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:ad:abc"), false)
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:local:a:b:c:1"), false)
        expectEqual(SpotifyArtworkURL.isTrackURI("spotify:episode:abc"), false)
    }

    do {
        let info: [AnyHashable: Any] = [
            "Track ID": "spotify:track:5jQI2r1RdgtuT8S3iG8zFC", "Name": "Lavender Haze", "Artist": "Taylor Swift",
            "Album": "Midnights", "Player State": "Playing", "Playback Position": 70.33, "Duration": 202395,
        ]
        let hint = SpotifyNotificationHint(userInfo: info)
        expectEqual(hint?.trackID, "spotify:track:5jQI2r1RdgtuT8S3iG8zFC")
        expectEqual(hint?.isAd, false)
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Taylor Swift"), true)
        expectEqual(hint?.matches(title: " lavender haze ", artist: "TAYLOR SWIFT"), true)
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Taylor Swift, Ice Spice"), true)
        expectEqual(hint?.matches(title: "Lavender Haze", artist: ""), true)
        expectEqual(hint?.matches(title: "Anti-Hero", artist: "Taylor Swift"), false)
        expectEqual(hint?.matches(title: "Lavender Haze", artist: "Someone Else"), false)
        expectEqual(hint?.matches(title: nil, artist: "Taylor Swift"), false)
        expectEqual(SpotifyNotificationHint(userInfo: ["Name": "x"]) == nil, true)
        expectEqual(SpotifyNotificationHint(userInfo: ["Track ID": "  "]) == nil, true)
        expectEqual(SpotifyNotificationHint(userInfo: nil) == nil, true)
        let ad = SpotifyNotificationHint(userInfo: ["Track ID": "spotify:ad:1234", "Name": "Spotify", "Artist": ""])
        expectEqual(ad?.isAd, true)
        expectEqual(ad?.matches(title: "Spotify", artist: "Some Advertiser"), true)
        let empty = SpotifyNotificationHint(trackID: "spotify:track:x", name: "", artist: "a")
        expectEqual(empty.matches(title: "", artist: "a"), false)
        expectEqual(SpotifyNotificationHint(trackID: "spotify:episode:x", name: "n", artist: "a").isAd, false)
    }

    do {
        typealias P = SpotifyPositionProbe
        let art = "https://i.scdn.co/image/ab67616d0000b273bb54dde68cd23e2a268ae0f5"
        let ok = P.parseProbeOutput("123456|spotify:track:5jQI2r1RdgtuT8S3iG8zFC|\(art)\n")
        expectEqual(ok?.position, 123.456)
        expectEqual(ok?.uri, "spotify:track:5jQI2r1RdgtuT8S3iG8zFC")
        expectEqual(ok?.artworkURL?.absoluteString, art)
        let adOut = P.parseProbeOutput("2000|spotify:ad:abc|missing value")
        expectEqual(adOut?.position, 2.0)
        expectEqual(adOut?.uri, "spotify:ad:abc")
        expectEqual(adOut?.artworkURL, nil)
        expectEqual(P.parseProbeOutput("12.5")?.position, 12.5)
        expectEqual(P.parseProbeOutput("") == nil, true)
        expectEqual(P.parseProbeOutput("   \n") == nil, true)
        expectEqual(P.parseProbeOutput("abc|x|y") == nil, true)
        expectEqual(P.parseProbeOutput("1500|")?.uri, nil)
        expectEqual(P.parseProbeOutput("1500|spotify:track:x|https://evil.example/x")?.artworkURL, nil)
    }

    do {
        expectEqual(SpotifyURI.deepLink("spotify:track:0WbMK4wrZ1wFSty9F7FCgu")?.absoluteString,
                    "spotify:track:0WbMK4wrZ1wFSty9F7FCgu")
        expectEqual(SpotifyURI.deepLink(" spotify:track:0WbMK4wrZ1wFSty9F7FCgu\n")?.absoluteString,
                    "spotify:track:0WbMK4wrZ1wFSty9F7FCgu")
        expectEqual(SpotifyURI.deepLink("spotify:episode:5aWVx8FGdvhY5r6AmN0vRq")?.absoluteString,
                    "spotify:episode:5aWVx8FGdvhY5r6AmN0vRq")
        expectEqual(SpotifyURI.deepLink("spotify:ad:5aWVx8FGdvhY5r6AmN0vRq"), nil)
        expectEqual(SpotifyURI.deepLink("spotify:local:a:b:c:1"), nil)
        expectEqual(SpotifyURI.deepLink("spotify:track:short"), nil)
        expectEqual(SpotifyURI.deepLink("spotify:track:0WbMK4wrZ1wFSty9F7FCg/"), nil)
        expectEqual(SpotifyURI.deepLink("spotify:track:0WbMK4wrZ1wFSty9F7FCgu:play"), nil)
        expectEqual(SpotifyURI.deepLink("https://open.spotify.com/track/0WbMK4wrZ1wFSty9F7FCgu"), nil)
        expectEqual(SpotifyURI.deepLink(""), nil)
    }

    do {
        typealias M = MusicPlaybackController
        expectEqual(M.spotifyPlaybackMode(fromModePart: "true;true"), .shuffle)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "false;true"), .list)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "false;false"), nil)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "true;false"), nil)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "true"), .shuffle)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "false;nil"), .list)
        expectEqual(M.spotifyPlaybackMode(fromModePart: "nil;true"), nil)
        expectEqual(M.spotifyPlaybackMode(fromModePart: ""), nil)
        expectEqual(M.spotifyPlaybackMode(fromModePart: " true ; true "), .shuffle)
    }
}

@MainActor
func runSpotifyWebProbeReadingTests() {
    typealias B = BrowserPositionProbe
    let art = "https://i.scdn.co/image/ab67616d0000e1a3189e41798cd255d340b21be9"
    let r = B.parseReading(fromOsascriptOutput: "\"168|0|\(art)\"")
    expectEqual(r?.seconds, 168)
    expectEqual(r?.artworkURL?.absoluteString, art)
    expectEqual(B.parseReading(fromOsascriptOutput: "168|0")?.seconds, 168)
    expectEqual(B.parseReading(fromOsascriptOutput: "168|0")?.artworkURL, nil)
    expectEqual(B.parseReading(fromOsascriptOutput: "168|1|\(art)") == nil, true)
    expectEqual(B.parseReading(fromOsascriptOutput: "168|0|")?.artworkURL, nil)
    expectEqual(B.parseReading(fromOsascriptOutput: "168|0|https://evil.example/x.jpg")?.artworkURL, nil)
    expectEqual(B.parseReading(fromOsascriptOutput: "NOTFOUND") == nil, true)
    expectEqual(B.parseReading(fromOsascriptOutput: "") == nil, true)
    expectEqual(B.parseSeconds(fromOsascriptOutput: "168|0|\(art)"), 168)
    expectEqual(B.parseSeconds(fromOsascriptOutput: "\"168|1\""), nil)
    if let url = r?.artworkURL {
        expectEqual(SpotifyArtworkURL.downloadCandidates(for: url).first?.absoluteString,
                    "https://i.scdn.co/image/ab67616d000082c1189e41798cd255d340b21be9")
    }
}
