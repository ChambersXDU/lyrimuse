import AVFoundation
import AppKit
import SwiftUI

struct MotionCoverView: NSViewRepresentable {

    let file: URL

    let isPlaying: Bool

    func makeNSView(context: Context) -> MotionCoverNSView {
        let view = MotionCoverNSView()
        view.load(file)
        view.setPlaying(isPlaying)
        return view
    }

    func updateNSView(_ view: MotionCoverNSView, context: Context) {
        view.load(file)
        view.setPlaying(isPlaying)
    }
}

final class MotionCoverNSView: NSView {
    private var player: AVQueuePlayer?

    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    private var desiredFile: URL?

    private var loadedFile: URL?
    private var wantsPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill

        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func load(_ file: URL) {
        desiredFile = file

        guard window != nil else { return }
        guard loadedFile != file else { return }
        loadedFile = file
        let item = AVPlayerItem(url: file)
        let queue = AVQueuePlayer()
        queue.isMuted = true

        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        player = queue
        if wantsPlaying { queue.play() }
    }

    func setPlaying(_ playing: Bool) {
        guard wantsPlaying != playing else { return }
        wantsPlaying = playing
        if playing { player?.play() } else { player?.pause() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            player?.pause()
            playerLayer.player = nil
            looper = nil
            player = nil
            loadedFile = nil
            wantsPlaying = false
        } else if let file = desiredFile {
            load(file)
        }
    }
}
