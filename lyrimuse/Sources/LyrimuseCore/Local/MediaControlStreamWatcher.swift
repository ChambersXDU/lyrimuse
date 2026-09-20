import Foundation
import OSLog

public struct MediaControlAnchorDigest {
    public let merged: [String: Any]
    public let anchorKey: String?
    public let tight: Bool
    public let anchorAge: Double?

    public let pausedAtArrival: Bool

    public let trackChangeKey: String?

    public let trackChangeAt: Date?

    public init(merged: [String: Any], anchorKey: String?, tight: Bool, anchorAge: Double?,
                pausedAtArrival: Bool = false, trackChangeKey: String? = nil, trackChangeAt: Date? = nil) {
        self.merged = merged
        self.anchorKey = anchorKey
        self.tight = tight
        self.anchorAge = anchorAge
        self.pausedAtArrival = pausedAtArrival
        self.trackChangeKey = trackChangeKey
        self.trackChangeAt = trackChangeAt
    }
}

@MainActor
public final class MediaControlStreamWatcher {
    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "mc-stream")

    private static let minRestartDelay: TimeInterval = 1
    private static let maxRestartDelay: TimeInterval = 30

    private let onEvent: () -> Void
    private var process: Process?
    private var restartWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = MediaControlStreamWatcher.minRestartDelay
    private var stopped = true

    private var buffer = Data()

    public init(onEvent: @escaping () -> Void) {
        self.onEvent = onEvent
    }

    public func start() {
        guard stopped else { return }
        stopped = false
        restartDelay = Self.minRestartDelay
        launch()
    }

    public func stop() {
        stopped = true
        restartWork?.cancel()
        restartWork = nil
        teardownProcess()
    }

    private func teardownProcess() {
        guard let process else { return }
        self.process = nil

        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        buffer.removeAll()
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let binary = MediaControlClient.binaryPath() else {

            Self.logger.info("media-control binary unavailable; staying on the 2s poll only")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)

        proc.arguments = ["stream", "--no-artwork"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData

            let arrivedAt = Date()
            guard !chunk.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(chunk, arrivedAt: arrivedAt) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTermination() }
        }

        do {
            try proc.run()
            process = proc
            Self.logger.info("media-control stream started (pid \(proc.processIdentifier))")
        } catch {
            Self.logger.error("failed to start media-control stream: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private var mergedPayload: [String: Any] = [:]

    private func consume(_ chunk: Data, arrivedAt: Date) {
        guard !stopped else { return }
        buffer.append(chunk)

        var fired = false
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            fired = true
            let digest = Self.digest(line: Data(line), merged: mergedPayload, arrivedAt: arrivedAt)
            mergedPayload = digest.merged
            if digest.pausedAtArrival {
                MediaControlClient.notePauseObserved(at: arrivedAt)
            }
            if let changed = digest.trackChangeKey, let at = digest.trackChangeAt {
                MediaControlClient.noteTrackChangeObserved(key: changed, at: at)
            }
            if let key = digest.anchorKey {
                MediaControlClient.noteStreamAnchorSighting(anchorKey: key, at: arrivedAt, tight: digest.tight)

                Self.logger.notice("anchor sighting tight=\(digest.tight) ageAtArrival=\(digest.anchorAge ?? -1, format: .fixed(precision: 3)) key=\(key, privacy: .public)")
            }
        }

        if fired {

            restartDelay = Self.minRestartDelay
            onEvent()
        }
    }

    public nonisolated static func digest(line: Data, merged: [String: Any], arrivedAt: Date) -> MediaControlAnchorDigest {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any]
        else { return MediaControlAnchorDigest(merged: merged, anchorKey: nil, tight: false, anchorAge: nil) }
        let isDiff = object["diff"] as? Bool ?? false
        var next: [String: Any] = isDiff ? merged : [:]
        for key in ["artist", "title", "elapsedTime", "timestamp"] where payload.keys.contains(key) {
            if payload[key] is NSNull {
                next.removeValue(forKey: key)
            } else {
                next[key] = payload[key]
            }
        }

        let paused = (payload["playing"] as? Bool) == false

        let changed = changedTrackKey(before: merged, after: next)
        guard payload.keys.contains("elapsedTime") || payload.keys.contains("timestamp") else {
            return MediaControlAnchorDigest(merged: next, anchorKey: nil, tight: false, anchorAge: nil,
                                            pausedAtArrival: paused,
                                            trackChangeKey: changed, trackChangeAt: changed == nil ? nil : arrivedAt)
        }
        let elapsed = (next["elapsedTime"] as? NSNumber)?.doubleValue
        let timestamp = next["timestamp"] as? String
        guard elapsed != nil || timestamp != nil else {
            return MediaControlAnchorDigest(merged: next, anchorKey: nil, tight: false, anchorAge: nil,
                                            pausedAtArrival: paused,
                                            trackChangeKey: changed, trackChangeAt: changed == nil ? nil : arrivedAt)
        }
        let key = MediaControlClient.anchorKey(
            artist: next["artist"] as? String, title: next["title"] as? String,
            elapsedTime: elapsed, timestamp: timestamp)
        let age = MediaControlClient.parseTimestamp(timestamp).map { arrivedAt.timeIntervalSince($0) }

        let tight = age.map { $0 >= -1 && $0 <= MediaControlClient.tightSightingMaxAge } ?? false
        return MediaControlAnchorDigest(merged: next, anchorKey: key, tight: tight, anchorAge: age,
                                        pausedAtArrival: paused, trackChangeKey: changed,
                                        trackChangeAt: changed == nil ? nil
                                            : trackChangeInstant(anchorTimestamp: MediaControlClient.parseTimestamp(timestamp),
                                                                 tight: tight, arrivedAt: arrivedAt))
    }

    public nonisolated static func changedTrackKey(before: [String: Any], after: [String: Any]) -> String? {
        let title = (after["title"] as? String) ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let now = MediaControlSnapshot.trackKey(artist: after["artist"] as? String, title: title)
        let was = MediaControlSnapshot.trackKey(artist: before["artist"] as? String, title: before["title"] as? String)
        return now == was ? nil : now
    }

    public nonisolated static func trackChangeInstant(anchorTimestamp: Date?, tight: Bool, arrivedAt: Date) -> Date {
        guard tight, let anchorTimestamp else { return arrivedAt }
        let instant = MediaControlClient.estimatedAnchorInstant(
            timestamp: anchorTimestamp,
            sighting: MediaControlClient.AnchorSighting(at: arrivedAt, tight: true))
        return min(instant, arrivedAt)
    }

    private func handleTermination() {
        guard !stopped else { return }
        Self.logger.info("media-control stream exited; restarting in \(self.restartDelay, format: .fixed(precision: 1))s")
        process = nil
        buffer.removeAll()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            self.launch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
    }
}
