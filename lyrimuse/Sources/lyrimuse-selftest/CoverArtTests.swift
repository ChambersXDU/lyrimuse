import LyrimuseCore
import Foundation
import CoreGraphics

@MainActor
func runCoverArtTests() {

    do {
        typealias R = EnrichCacheReader
        let covers = [
            "Sebastien Najand/英雄联盟|PROJECT: Ashe|PROJECT: Ashe": "https://cover/ashe",
            "英雄联盟/Sara Skinner|Bring Home The Glory|Bring Home The Glory": "https://cover/glory",
            "英雄联盟/Against the Current|Legends Never Die|Legends Never Die": "https://cover/legends",
            "英雄联盟 & The Crystal Method|Senna, the Redeemer|Senna, the Redeemer": "https://cover/senna",
            "英雄联盟 & Mako & The Word Alive & The Glitch Mob|RISE|RISE": "https://cover/rise",
            "Edouard Brenneisen & 英雄联盟|Jhin, the Virtuoso|Jhin, the Virtuoso": "https://cover/jhin",

            "Imagine Dragons|Warriors|Warriors (Official Anthem of League of Legends 2014 World Championship)": "https://cover/warriors",
            "英雄联盟|Aphelios, the Weapon of the Faithful|Aphelios, the Weapon of the Faithful": "https://cover/aphelios",
        ]
        let index = R.coverIndexByArtistTitle(covers)
        func cover(_ artist: String, _ title: String) -> String? {
            R.coverURLString(in: index, artist: artist, title: title)
        }

        expectEqual(cover("Sebastien Najand", "PROJECT: Ashe"), "https://cover/ashe")
        expectEqual(cover("英雄联盟", "Bring Home The Glory"), "https://cover/glory")
        expectEqual(cover("英雄联盟", "Legends Never Die"), "https://cover/legends")
        expectEqual(cover("英雄联盟", "Senna, the Redeemer"), "https://cover/senna")
        expectEqual(cover("英雄联盟", "RISE"), "https://cover/rise")

        expectEqual(cover("Edouard Brenneisen", "Jhin, The Virtuoso"), "https://cover/jhin")

        expectEqual(cover("Imagine Dragons", "Warriors"), "https://cover/warriors")
        expectEqual(cover("英雄联盟", "Aphelios, the Weapon of the Faithful"), "https://cover/aphelios")

        let single = R.coverIndexByArtistTitle(["Daniel Caesar|Toronto 2014|NEVER ENOUGH": "https://cover/toronto"])
        expectEqual(R.coverURLString(in: single, artist: "Daniel Caesar & Mustafa", title: "Toronto 2014"),
                    "https://cover/toronto")

        let both = R.coverIndexByArtistTitle([
            "英雄联盟|RISE|The Music of League of Legends": "https://cover/exact",
            "英雄联盟 & Mako|RISE|RISE": "https://cover/collab",
        ])
        expectEqual(R.coverURLString(in: both, artist: "英雄联盟", title: "RISE"), "https://cover/exact")

        let kda = R.coverIndexByArtistTitle(["K/DA|POP/STARS|POP/STARS": "https://cover/kda"])
        expectEqual(R.coverURLString(in: kda, artist: "K/DA", title: "POP/STARS"), "https://cover/kda")

        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), true)
        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: "The Easy Ride 演唱會 (Live)"), true)
        expectEqual(R.coverAlbumVerified(coverAlbum: "Get A Life (Live)",
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), false)
        expectEqual(R.coverAlbumVerified(coverAlbum: nil,
                                         requestedAlbum: "The Easy Ride 演唱会 (Live)"), false)
        expectEqual(R.coverAlbumVerified(coverAlbum: "The Easy Ride 演唱会 (Live)",
                                         requestedAlbum: ""), false)
    }

    do {
        typealias M = MusicCatalogSearch
        func item(_ artist: String, _ track: String, _ album: String,
                  art: String? = "https://is1.mzstatic.com/x/100x100bb.jpg") -> M.Item {
            M.Item(trackName: track, artistName: artist, collectionName: album,
                   trackViewUrl: nil, artistViewUrl: nil, collectionViewUrl: nil, artworkUrl100: art)
        }
        let 地表最强 = "周杰伦地表最强世界巡回演唱会 (Live)"

        expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/100x100bb.jpg")?.absoluteString,
                    "https://is1.mzstatic.com/x/600x600bb.jpg")
        expectEqual(M.upscaleArtwork("https://is1.mzstatic.com/x/64x64.jpg")?.absoluteString,
                    "https://is1.mzstatic.com/x/64x64.jpg")
        expectEqual(M.upscaleArtwork(nil) == nil, true)

        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch)

        expectEqual(M.pickArtwork([item("周杰伦", "开不了口 (Live)", 地表最强)],
                                  title: "开不了口 (live)", artist: "周杰倫", album: 地表最强)?.confidence,
                    .albumMatch)

        expectEqual(M.pickArtwork([item("周杰伦 & 派伟俊", "我要夏天 (Live)", 地表最强)],
                                  title: "我要夏天 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch)

        let mixed = [item("周杰伦", "青花瓷 (Live)", "魔天伦世界巡回演唱会 (Live)"),
                     item("周杰伦", "青花瓷 (Live)", 地表最强)]
        let picked = M.pickArtwork(mixed, title: "青花瓷 (Live)", artist: "周杰伦", album: 地表最强)
        expectEqual(picked?.confidence, .albumMatch)
        expectEqual(picked?.matchedAlbum, 地表最强)

        expectEqual(M.pickArtwork([item("Beyond", "光辉岁月", "Beyond - 25th Anniversary")],
                                  title: "光辉岁月", artist: "Beyond", album: "BEYOND音乐大全 101")?.confidence,
                    .trackOnly)

        expectEqual(M.pickArtwork([item("鱼翅Fin", "无声的告别是对往事的礼赞", "工作札记 - EP")],
                                  title: "情非得已 (微醺版)", artist: "微醺卡带",
                                  album: "情非得已（微醺版）") == nil,
                    true)

        expectEqual(M.pickArtwork([item("周杰伦", "美人鱼", "哎呦, 不错哦")],
                                  title: "美人鱼 (Live)", artist: "周杰伦", album: 地表最强) == nil,
                    true)

        expectEqual(M.pickArtwork([item("Cailin Russo", "Phoenix (feat. Chrissy Costanza)", "Phoenix")],
                                  title: "Phoenix", artist: "Cailin Russo", album: "Phoenix")?.confidence,
                    .albumMatch)

        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强, art: nil),
                                   item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: 地表最强)?.confidence,
                    .albumMatch)
        expectEqual(M.pickArtwork([], title: "x", artist: "y", album: nil) == nil, true)

        expectEqual(M.pickArtwork([item("周杰伦", "床边故事 (Live)", 地表最强)],
                                  title: "床边故事 (Live)", artist: "周杰伦", album: nil)?.confidence,
                    .trackOnly)
    }

    do {
        func accent(_ r: Double, _ g: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
            LocalPlaybackSource.brightenedAccent(r: r, g: g, b: b)
        }
        func brightness(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, max(c.g, c.b)) }
        func saturation(_ c: (r: Double, g: Double, b: Double)) -> Double {
            let mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b))
            return mx <= 0 ? 0 : (mx - mn) / mx
        }

        let nearBlack = accent(2/255, 1/255, 3/255)
        expectEqual(saturation(nearBlack) < 0.01, true)
        expectEqual(accent(0, 0, 0) == accent(2/255, 1/255, 3/255), true)

        let bright = accent(0.9, 0.4, 0.4)
        expectEqual(bright.r == 0.9 && bright.g == 0.4, true)

        let darkRed = accent(0.30, 0.02, 0.02)
        expectEqual(abs(brightness(darkRed) - 0.62) < 0.001, true)
        expectEqual(saturation(darkRed) < saturation((r: 0.30, g: 0.02, b: 0.02)), true)

        expectEqual(darkRed.r > darkRed.g && darkRed.r > darkRed.b, true)
        let darkBlue = accent(0.02, 0.05, 0.30)
        expectEqual(darkBlue.b > darkBlue.r && darkBlue.b > darkBlue.g, true)
        let darkGreen = accent(0.03, 0.28, 0.05)
        expectEqual(darkGreen.g > darkGreen.r && darkGreen.g > darkGreen.b, true)

        let darkGray = accent(0.2, 0.2, 0.2)
        expectEqual(saturation(darkGray) < 0.01, true)

        var bad = 0
        for i in 0 ... 20 {
            for j in 0 ... 20 {
                let c = accent(Double(i) / 20, Double(j) / 20, 0.5)
                if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                if brightness(c) < 0.61 { bad += 1 }
            }
        }
        expectEqual(bad, 0)
    }

    do {

        expectEqual(MediaControlSnapshot.trackKey(artist: "周杰伦", title: "以父之名"),
                    "周杰伦|以父之名")
        expectEqual(MediaControlSnapshot.trackKey(artist: nil, title: nil), "|")

        expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|以父之名"),
                    true)
        expectEqual(LocalPlaybackSource.artworkKeyMatches("周杰伦|以父之名", "周杰伦|一路向北"),
                    false)

        expectEqual(LocalPlaybackSource.artworkKeyMatches("Michael Jackson|2 BAD", "Michael Jackson|2 Bad"),
                    true)
    }

    do {
        func fit(_ c: (Double, Double, Double), stroke: (Double, Double, Double),
                 minContrast: Double = 3.0) -> (r: Double, g: Double, b: Double) {
            LocalPlaybackSource.accentAgainstStroke(
                r: c.0, g: c.1, b: c.2,
                strokeR: stroke.0, strokeG: stroke.1, strokeB: stroke.2,
                minContrast: minContrast)
        }
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
            LocalPlaybackSource.relativeLuminance(r: c.r, g: c.g, b: c.b)
        }
        func contrastWith(_ c: (r: Double, g: Double, b: Double),
                          _ stroke: (Double, Double, Double)) -> Double {
            LocalPlaybackSource.contrastRatio(
                lum(c), LocalPlaybackSource.relativeLuminance(r: stroke.0, g: stroke.1, b: stroke.2))
        }

        let white = (1.0, 1.0, 1.0)
        let black = (0.0, 0.0, 0.0)

        let grey = fit((0.72, 0.72, 0.72), stroke: white)
        expectEqual(contrastWith(grey, white) >= 2.99, true)
        expectEqual(lum(grey) < LocalPlaybackSource.relativeLuminance(r: 0.72, g: 0.72, b: 0.72),
                    true)

        let nearBlack = fit((2 / 255.0, 1 / 255.0, 3 / 255.0), stroke: white)
        expectEqual(abs(nearBlack.r - nearBlack.g) < 1e-9 && abs(nearBlack.g - nearBlack.b) < 1e-9,
                    true)
        expectEqual(nearBlack.r < 0.03, true)

        let deep = (0.15, 0.10, 0.30)
        let untouched = fit(deep, stroke: white)
        expectEqual(untouched == (r: deep.0, g: deep.1, b: deep.2), true)

        let darkOnBlack = fit((0.12, 0.10, 0.08), stroke: black)
        expectEqual(contrastWith(darkOnBlack, black) >= 2.99, true)
        expectEqual(lum(darkOnBlack) > LocalPlaybackSource.relativeLuminance(r: 0.12, g: 0.10, b: 0.08),
                    true)

        let midStroke = (0.5, 0.5, 0.5)
        let onMid = fit((0.55, 0.52, 0.50), stroke: midStroke, minContrast: 7.0)
        let bestEndpoint = max(contrastWith((r: 0, g: 0, b: 0), midStroke),
                               contrastWith((r: 1, g: 1, b: 1), midStroke))
        expectEqual(abs(contrastWith(onMid, midStroke) - bestEndpoint) < 0.01, true)

        let paleStroke = (0.47, 0.47, 0.47)
        let paleCandidate = (0.85, 0.85, 0.85)
        let onPale = fit(paleCandidate, stroke: paleStroke, minContrast: 4.5)
        expectEqual(lum(onPale) > lum((r: paleStroke.0, g: paleStroke.1, b: paleStroke.2)), true)
        expectEqual(contrastWith(onPale, paleStroke) >= 4.2, true)

        var bad = 0, unreachable = 0
        for si in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let stroke = (si, si, si)
            let sl = LocalPlaybackSource.relativeLuminance(r: si, g: si, b: si)

            let reachable = max(LocalPlaybackSource.contrastRatio(sl, 0),
                                LocalPlaybackSource.contrastRatio(sl, 1)) >= 3.0
            for i in 0 ... 12 {
                for j in 0 ... 12 {
                    for k in [0.0, 0.5, 1.0] {
                        let c = fit((Double(i) / 12, Double(j) / 12, k), stroke: stroke)
                        if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 { bad += 1 }
                        if reachable, contrastWith(c, stroke) < 2.99 { unreachable += 1 }
                    }
                }
            }
        }
        expectEqual(bad, 0)
        expectEqual(unreachable, 0)
    }

    do {
        func native(_ s: String) -> String {
            EnrichCacheReader.nativeSizedCoverURL(URL(string: s)!).absoluteString
        }

        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg?param=600y600"),
            "https://p1.music.126.net/abc==/1099.jpg")

        expectEqual(
            native("https://p2.music.126.net/abc==/1099.jpg?param=300y300"),
            "https://p2.music.126.net/abc==/1099.jpg")

        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg"),
            "https://p1.music.126.net/abc==/1099.jpg")

        expectEqual(
            native("https://p1.music.126.net/abc==/1099.jpg?param=600y600&x=1"),
            "https://p1.music.126.net/abc==/1099.jpg?x=1")

        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R300x300M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg")
        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R500x500M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg")

        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg"),
            "https://y.qq.com/music/photo_new/T002R800x800M0000017AN4b0vdUG1.jpg")

        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg"),
            "https://y.qq.com/music/photo_new/T002R1000x1000M000abc.jpg")

        expectEqual(
            native("https://y.qq.com/music/photo_new/T002R500x500M000.jpg?param=600y600"),
            "https://y.qq.com/music/photo_new/T002R800x800M000.jpg?param=600y600")

        expectEqual(
            native("https://y.gtimg.cn/music/photo_new/T001R300x300M000004UdEhN3Hb7vN_3.jpg"),
            "https://y.gtimg.cn/music/photo_new/T001R800x800M000004UdEhN3Hb7vN_3.jpg")

        expectEqual(
            native("https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49"),
            "https://y.qq.com/n/ryqq/songDetail/000FTx4w1obE49")

        expectEqual(
            native("https://y.qq.com/music/photo_new/mystery.jpg"),
            "https://y.qq.com/music/photo_new/mystery.jpg")

        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg")
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/1200x1200bb.jpg")

        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/2000x2000bb.jpg")

        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600sr.jpg")
        expectEqual(
            native("https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg"),
            "https://is1-ssl.mzstatic.com/image/thumb/a.jpg/600x600bb-60.jpg")

        expectEqual(
            native("https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg"),
            "https://evilmzstatic.com/image/thumb/a.jpg/600x600bb.jpg")

        expectEqual(
            native("https://evil-music.126.net.example.com/a.jpg?param=600y600"),
            "https://evil-music.126.net.example.com/a.jpg?param=600y600")

        expectEqual(
            native("https://evilmusic.126.net/a.jpg?param=600y600"),
            "https://evilmusic.126.net/a.jpg?param=600y600")
    }

    do {
        typealias G = CoverArtReplacementGate
        let t = 300

        expectEqual(G.reason(width: 320, height: 180, lowResThreshold: t), .notCoverShaped)
        expectEqual(G.reason(width: 544, height: 544, lowResThreshold: t), nil)

        expectEqual(G.reason(width: 180, height: 320, lowResThreshold: t), .notCoverShaped)
        expectEqual(G.reason(width: 1280, height: 720, lowResThreshold: t), .notCoverShaped)

        expectEqual(G.reason(width: 100, height: 100, lowResThreshold: t), .lowRes)
        expectEqual(G.reason(width: 300, height: 300, lowResThreshold: t), .lowRes)
        expectEqual(G.reason(width: 301, height: 301, lowResThreshold: t), nil)

        expectEqual(G.reason(width: 0, height: 0, lowResThreshold: t), nil)

        expectEqual(G.isCoverShaped(width: 1000, height: 850), true)
        expectEqual(G.isCoverShaped(width: 1000, height: 849), false)
        expectEqual(G.maxAspectSkew, 0.15)

        expectEqual(G.reason(width: 600, height: 520, lowResThreshold: t), nil)

        expectEqual(G.accepts(candidateWidth: 600, candidateHeight: 600, systemWidth: 300, reason: .lowRes), true)
        expectEqual(G.accepts(candidateWidth: 300, candidateHeight: 300, systemWidth: 300, reason: .lowRes), false)
        expectEqual(G.accepts(candidateWidth: 1200, candidateHeight: 1200, systemWidth: 320, reason: .notCoverShaped), true)
        expectEqual(G.accepts(candidateWidth: 600, candidateHeight: 600, systemWidth: 1280, reason: .notCoverShaped), true)
        expectEqual(G.accepts(candidateWidth: 640, candidateHeight: 360, systemWidth: 320, reason: .notCoverShaped), false)
    }

    do {
        typealias T = ArtworkThumbnail

        func rgba(_ image: CGImage) -> [UInt8] {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return bytes }
            bytes.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return bytes
        }

        func synthesize(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = fill(x, y)
                    let o = (y * width + x) * 4
                    bytes[o] = r; bytes[o + 1] = g; bytes[o + 2] = b
                }
            }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        if let board = synthesize(width: 600, height: 600, fill: { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }) {
            if let thumb = T.squareBitmap(from: board, pixelSide: 46) {
                expectEqual(thumb.width, 46)
                expectEqual(thumb.height, 46)
                let px = rgba(thumb)
                var extremes = 0
                for i in stride(from: 0, to: px.count, by: 4) where px[i] < 64 || px[i] > 192 { extremes += 1 }
                expectEqual(extremes, 0)
            } else {
                expectEqual(false, true)
            }

            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: 46, height: 46, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.draw(board, in: CGRect(x: 0, y: 0, width: 46, height: 46))
                if let naive = ctx.makeImage() {
                    let px = rgba(naive)
                    var extremes = 0
                    for i in stride(from: 0, to: px.count, by: 4) where px[i] < 64 || px[i] > 192 { extremes += 1 }
                    expectEqual(extremes > 46 * 46 / 2, true)
                }
            }
        } else {
            expectEqual(false, true)
        }

        if let wide = synthesize(width: 600, height: 300, fill: { x, _ in x < 150 ? (255, 0, 0) : (x < 450 ? (0, 255, 0) : (0, 0, 255)) }),
           let thumb = T.squareBitmap(from: wide, pixelSide: 32) {
            let px = rgba(thumb)
            var nonGreen = 0
            for i in stride(from: 0, to: px.count, by: 4) where !(px[i] < 16 && px[i + 1] > 239 && px[i + 2] < 16) { nonGreen += 1 }
            expectEqual(nonGreen, 0)
        } else {
            expectEqual(false, true)
        }

        if let tall = synthesize(width: 300, height: 600, fill: { _, y in y < 150 ? (255, 0, 0) : (y < 450 ? (0, 255, 0) : (0, 0, 255)) }),
           let thumb = T.squareBitmap(from: tall, pixelSide: 32) {
            let px = rgba(thumb)
            var nonGreen = 0
            for i in stride(from: 0, to: px.count, by: 4) where !(px[i] < 16 && px[i + 1] > 239 && px[i + 2] < 16) { nonGreen += 1 }
            expectEqual(nonGreen, 0)
        } else {
            expectEqual(false, true)
        }

        if let board = synthesize(width: 8, height: 8, fill: { _, _ in (0, 0, 0) }) {
            expectEqual(T.squareBitmap(from: board, pixelSide: 0) == nil, true)
        }
    }

    do {
        typealias M = MotionCoverManifest
        let base = "https://mvod.itunes.apple.com/itunes-assets/HLSVideo211/v4/b4/00/a8/x"
        let master = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS

        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=173201,_AVG-BANDWIDTH=173201,BANDWIDTH=177631,VIDEO-RANGE=SDR,CODECS="avc1.64001f",RESOLUTION=486x486,URI="\(base)/P_trickPlay_gr210_sdr_486x486_iframes.m3u8"
        #EXT-X-I-FRAME-STREAM-INF:AVERAGE-BANDWIDTH=887781,_AVG-BANDWIDTH=887781,BANDWIDTH=942325,VIDEO-RANGE=SDR,CODECS="avc1.640020",RESOLUTION=1080x1080,URI="\(base)/P_trickPlay_gr265_sdr_1080x1080_iframes.m3u8"

        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=265893,_AVG-BANDWIDTH=265893,BANDWIDTH=334704,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=360x360,STABLE-VARIANT-ID="dfb6"
        \(base)/P_Anull_video_gr203_sdr_360x360.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=771275,_AVG-BANDWIDTH=771275,BANDWIDTH=983664,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=486x486,STABLE-VARIANT-ID="39f3"
        \(base)/P_Anull_video_gr210_sdr_486x486.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1118698,_AVG-BANDWIDTH=1118698,BANDWIDTH=1448322,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=486x486,STABLE-VARIANT-ID="b709"
        \(base)/P_Anull_video_gr220_sdr_486x486.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2154918,_AVG-BANDWIDTH=2154918,BANDWIDTH=2887412,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=768x768,STABLE-VARIANT-ID="99cf"
        \(base)/P_Anull_video_gr240_sdr_768x768.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1577673,_AVG-BANDWIDTH=1577673,BANDWIDTH=2128046,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="hvc1.2.20000000.L123.B0",FRAME-RATE=24.000,RESOLUTION=768x768,STABLE-VARIANT-ID="9263"
        \(base)/P_Anull_video_gr540_sdr_768x768.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=2868023,_AVG-BANDWIDTH=2868023,BANDWIDTH=3704874,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE,CODECS="avc1.64001f",FRAME-RATE=24.000,RESOLUTION=960x960,STABLE-VARIANT-ID="d2b0"
        \(base)/P_Anull_video_gr250_sdr_960x960.m3u8
        """
        let vs = M.parseVariants(master: master)
        expectEqual(vs.count, 6)
        expectEqual(vs.map(\.width), [360, 486, 486, 768, 768, 960])
        expectEqual(vs.filter(\.isHEVC).count, 1)
        expectEqual(vs[0].bandwidth, 265893)

        expectEqual(M.pick(vs, minimumWidth: 920)?.width, 960)
        expectEqual(M.pick(vs, minimumWidth: 920)?.isHEVC, false)

        expectEqual(M.pick(vs, minimumWidth: 64)?.width, 360)

        expectEqual(M.pick(vs, minimumWidth: 400)?.bandwidth, 771275)

        expectEqual(M.pick(vs, minimumWidth: 500)?.isHEVC, false)

        expectEqual(M.pick(vs, minimumWidth: 4096)?.width, 960)
        expectEqual(M.pick([], minimumWidth: 920) == nil, true)

        let variant = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="P_Anull_video_gr240_sdr_768x768-.mp4",BYTERANGE="877@0"
        #EXTINF:4.00000,
        #EXT-X-BYTERANGE:600435@877
        P_Anull_video_gr240_sdr_768x768-.mp4
        #EXTINF:4.00000,
        #EXT-X-BYTERANGE:1331742@601312
        P_Anull_video_gr240_sdr_768x768-.mp4
        #EXT-X-ENDLIST
        """
        expectEqual(M.mediaFileName(fromVariant: variant), "P_Anull_video_gr240_sdr_768x768-.mp4")
        expectEqual(M.mediaFileName(fromVariant: "#EXTM3U\n#EXT-X-ENDLIST") == nil, true)

        let vbase = URL(string: "\(base)/P_Anull_video_gr240_sdr_768x768.m3u8")!
        expectEqual(M.absolute("P_Anull_video_gr240_sdr_768x768-.mp4", relativeTo: vbase)?.absoluteString,
                    "\(base)/P_Anull_video_gr240_sdr_768x768-.mp4")
        expectEqual(M.absolute("https://other/x.mp4", relativeTo: vbase)?.absoluteString, "https://other/x.mp4")

        expectEqual(M.attribute("CODECS", in: "BANDWIDTH=1,CODECS=\"avc1.64001f,mp4a.40.2\",X=2"),
                    "avc1.64001f,mp4a.40.2")
        expectEqual(M.attribute("BANDWIDTH", in: "AVERAGE-BANDWIDTH=111,BANDWIDTH=222"), "222")
        expectEqual(M.attribute("RESOLUTION", in: "A=1,RESOLUTION=768x768"), "768x768")
        expectEqual(M.attribute("MISSING", in: "A=1") == nil, true)
        expectEqual(M.parseResolution("960x960")?.0, 960)
        expectEqual(M.parseResolution("bad") == nil, true)
    }
}
