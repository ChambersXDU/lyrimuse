import Foundation
import LyrimuseCore
import OSLog
import AppKit
import Darwin

enum DiagnosticsExporter {
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Lyrimuse-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    @MainActor
    static func exportInteractively() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let head = stateLines()
        let secrets = ConfigStore.shared.secretsForRedaction

        let currentTrackLines = currentTrackLyricsLines()
        Task { @MainActor in
            let logs = await Task.detached(priority: .userInitiated) {
                logLines(secrets: secrets, currentTrackLines: currentTrackLines)
            }.value
            let report = (head + logs).joined(separator: "\n")
            try? report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @MainActor
    static func buildReport() -> String {
        return (stateLines() + logLines(secrets: ConfigStore.shared.secretsForRedaction,
                                        currentTrackLines: currentTrackLyricsLines()))
            .joined(separator: "\n")
    }

    private static func describe(_ state: JSONConfigDocument.LoadState) -> String {
        switch state {
        case .missing: return "missing"
        case .loaded: return "ok"
        case .corrupt(let reason): return "CORRUPT — \(reason)"
        }
    }

    @MainActor
    private static func stateLines() -> [String] {
        var lines: [String] = []

        lines.append("Lyrimuse Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("== System ==")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        var isTranslated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let translated = sysctlbyname("sysctl.proc_translated", &isTranslated, &size, nil, 0) == 0
            && isTranslated == 1
        #if arch(arm64)
        let binaryArch = "arm64"
        #else
        let binaryArch = "x86_64"
        #endif
        lines.append("Architecture: \(binaryArch)" + (translated ? " (running under Rosetta)" : ""))
        lines.append("")

        lines.append("== State ==")
        let settings = AppSettings.shared
        let config = ConfigStore.shared
        lines.append("Automation permission: \(MusicAutomationPermission.check(askIfNeeded: false))")

        switch MediaControlHealth.shared.state {
        case .unknown: lines.append("media-control channel: not checked yet")
        case .healthy: lines.append("media-control channel: healthy")
        case .unavailable(let message): lines.append("media-control channel: UNAVAILABLE — \(message)")
        }

        lines.append("Player (setting): \(PlaybackPlayerPreference.selected.map(\.rawValue).sorted().joined(separator: ", "))")

        lines.append("Player (last detected): \(PlaybackCoordinator.shared.resolvedPlayerDescription)")
        lines.append("Collector service enabled (setting): \(settings.collectorServiceEnabled)")

        lines.append("Collector service state: \(CollectorServiceManager.state)")

        lines.append("config.json: \(describe(config.fileState))")
        lines.append("lyrimuse-features.json: \(describe(FeatureSettingsStore.shared.fileState))")
        lines.append("App language: \(settings.appLanguage)")
        lines.append("Classic overlay enabled: \(settings.classicOverlayEnabled)")
        lines.append("ListenBrainz configured (submit): \(config.isListenBrainzConfigured)")

        lines.append("ListenBrainz readable (digests/bridge): \(config.isListenBrainzReadable)")
        lines.append("State relay configured: \(config.stateRelayMissingHint() == nil)")
        lines.append("Push notification configured: \(config.pushMissingHint() == nil)")
        lines.append("")

        lines.append("== Windows ==")
        let interestingWindows = NSApp.windows.filter { !$0.title.isEmpty || $0.isVisible }
        if interestingWindows.isEmpty {
            lines.append("(no windows)")
        } else {
            for win in interestingWindows {
                let screenIndex = win.screen.flatMap { s in NSScreen.screens.firstIndex(where: { $0 === s }) }
                let f = win.frame
                lines.append("- \"\(win.title.isEmpty ? "(untitled)" : win.title)\":"
                             + " visible=\(win.isVisible) miniaturized=\(win.isMiniaturized)"
                             + " frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
                             + " screen=\(screenIndex.map(String.init) ?? "none")")
            }
        }

        let screenSummaries = NSScreen.screens.enumerated().map { i, s in
            "#\(i) \(Int(s.frame.width))x\(Int(s.frame.height))@\(String(format: "%.1f", s.backingScaleFactor))x"
        }
        lines.append("Screens: \(NSScreen.screens.count) — \(screenSummaries.joined(separator: ", "))")
        lines.append("")

        let clock = LocalPlaybackSource.shared.clockSnapshot
        lines.append("== Playback clock ==")
        lines.append("Playing: \(clock.isPlaying)  |  has lyrics: \(clock.hasLyrics)")

        lines.append("Position source tier: \(clock.tier)")

        lines.append(String(format: "Servo error EMA: %.3fs", clock.posErrEMASecs))

        lines.append(String(format: "Reported bias: %.3fs", clock.reportedBiasSecs))
        if let rate = clock.anchorRate, let fresh = clock.anchorFresh, let age = clock.anchorAgeSecs {

            lines.append(String(format: "Anchor: rate=%.2f fresh=%@ age=%.1fs",
                                rate, fresh ? "yes" : "no", age))
        } else {
            lines.append("Anchor: none (paused or no track)")
        }

        lines.append("Lyrics offset (effective): \(clock.effectiveLyricsOffsetMs)ms"
                     + "  |  from LRC [offset:]: \(clock.lrcOffsetMs)ms")

        lines.append("Current line fill settled: \(clock.fillSettled)")
        lines.append("")

        return lines
    }

    private static func logLines(secrets: [String: String], currentTrackLines: [String]?) -> [String] {
        var lines: [String] = []
        lines.append("== App Log (last 24h, UTC, subsystem me.yudaotor.lyrimuse) ==")
        lines.append(contentsOf: collapseRepeatedLines(
            recentAppLogLines().map { LogRedactor.redactAll($0, secrets: secrets) }))
        lines.append("")

        lines.append("== Collector Log (last 4h, UTC) ==")
        lines.append(contentsOf: collapseRepeatedLines(
            recentCollectorLogLines().map { LogRedactor.redactAll($0, secrets: secrets) }))
        lines.append("")

        lines.append("== App stderr (\(LogFiles.appStderr.lastPathComponent), last 100 lines) ==")
        lines.append(contentsOf: recentAppStderrLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        lines.append("== Recent Crash Reports (~/Library/Logs/DiagnosticReports, last 7 days) ==")
        lines.append(contentsOf: recentCrashReportLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        lines.append("== Collector Health Check (`collector healthcheck`) ==")
        lines.append(contentsOf: collectorHealthCheckLines().map { LogRedactor.redactAll($0, secrets: secrets) })
        lines.append("")

        if let currentTrackLines {
            lines.append("== Current Track Lyrics Resolution ==")
            lines.append(contentsOf: currentTrackLines)
            lines.append("")
        }

        return lines
    }

    private static func recentAppLogLines(hours: Int = 24) -> [String] {
        guard let store = try? OSLogStore(scope: .system) else {
            return ["(could not open log store)"]
        }
        let position = store.position(date: Date().addingTimeInterval(-Double(hours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", "me.yudaotor.lyrimuse")
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return ["(could not read log entries)"]
        }
        var lines: [String] = []
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            lines.append("\(logEntry.date) [\(logEntry.category)] \(logEntry.composedMessage)")
        }
        return lines.isEmpty ? ["(no entries in the last \(hours)h)"] : lines
    }

    private static func recentCrashReportLines(days: Int = 7, perProcessLimit: Int = 3) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        func tilde(_ text: String) -> String { text.replacingOccurrences(of: home.path, with: "~") }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dir.path)
        } catch {
            return [tilde("(cannot list \(dir.path): \(error.localizedDescription))")]
        }

        let executable = Bundle.main.executableURL?.lastPathComponent ?? "lyrimuse"
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var matched: [CrashReportSummary] = []
        var scanned = 0
        var problems: [String] = []
        for name in names where name.hasSuffix(".ips") && (name.hasPrefix("\(executable)-") || name.hasPrefix("collector-")) {
            let url = dir.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= cutoff else { continue }
            scanned += 1
            guard let data = try? Data(contentsOf: url) else { problems.append("\(name): unreadable"); continue }
            guard let summary = CrashReportSummary.parse(fileName: name, data: data) else {
                problems.append("\(name): unparseable"); continue
            }
            guard summary.belongsToApp(executableName: executable,
                                       bundleIdentifier: LyrimuseIdentity.bundleIdentifier,
                                       appDisplayName: LyrimuseIdentity.displayName) else { continue }
            matched.append(summary)
        }
        var lines: [String] = []
        if matched.isEmpty {
            lines.append("(no crash reports for \(LyrimuseIdentity.displayName) / collector in the last \(days) days; \(scanned) candidate file(s) scanned)")
        } else {
            let shown = CrashReportSummary.select(matched, perProcessLimit: perProcessLimit)
            lines.append("\(matched.count) report(s) in the last \(days) days; showing up to \(perProcessLimit) per process (\(shown.count) shown)")
            for summary in shown { lines.append(contentsOf: summary.renderLines()) }
        }
        lines.append(contentsOf: problems.map { "(\($0))" })
        return lines.map(tilde)
    }

    private static func recentAppStderrLines(maxLines: Int = 100) -> [String] {
        guard let content = try? String(contentsOf: LogFiles.appStderr, encoding: .utf8) else {
            return ["(no \(LogFiles.appStderr.lastPathComponent) yet: the app creates it at launch; a missing file means this build predates the in-process redirect or the Logs folder is not writable)"]
        }
        let all = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return all.isEmpty ? ["(empty)"] : Array(all.suffix(maxLines))
    }

    private static func recentCollectorLogLines(hours: Double = 4, hardLineCap: Int = 5000) -> [String] {
        let path = LogFiles.collector
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return ["(could not read \(path.path))"]
        }
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !allLines.isEmpty else { return ["(empty log file)"] }

        let cutoff = Date().addingTimeInterval(-hours * 3600)

        var startIndex = 0
        for i in stride(from: allLines.count - 1, through: 0, by: -1) {
            guard let date = CollectorLogLine.timestamp(of: allLines[i]) else { continue }
            if date < cutoff {
                startIndex = i + 1
                break
            }
            startIndex = i
        }
        let windowed = Array(allLines[startIndex...])
        return windowed.count > hardLineCap ? Array(windowed.suffix(hardLineCap)) : windowed
    }

    private static func collapseRepeatedLines(_ lines: [String], minRepeat: Int = 12) -> [String] {
        func template(_ line: String) -> String {
            var out = ""
            out.reserveCapacity(line.count)
            var lastWasDigit = false
            for ch in line {
                if ch.isASCII, ch.isNumber {
                    if !lastWasDigit { out.append("#") }
                    lastWasDigit = true
                } else {
                    out.append(ch)
                    lastWasDigit = false
                }
            }
            return out
        }

        var indicesByTemplate: [String: [Int]] = [:]
        for (i, line) in lines.enumerated() {
            indicesByTemplate[template(line), default: []].append(i)
        }

        var dropped = Set<Int>()
        var insertAfter: [Int: String] = [:]
        for indices in indicesByTemplate.values where indices.count >= minRepeat {
            let middle = indices.dropFirst().dropLast()
            for i in middle { dropped.insert(i) }
            insertAfter[indices.first!] =
                "    ⋯ 以上这类日志又重复了 \(middle.count) 次（已省略，下一行是最后一次出现）⋯"
        }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            if dropped.contains(i) { continue }
            out.append(line)
            if let note = insertAfter[i] { out.append(note) }
        }
        return out
    }

    private static func collectorHealthCheckLines() -> [String] {
        let collectorPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/collector").path
        guard FileManager.default.isExecutableFile(atPath: collectorPath) else {
            return ["(collector binary not found at \(collectorPath))"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: collectorPath)

        process.environment = LyrimusePaths.collectorProcessEnvironment()
        process.arguments = ["healthcheck"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ["(failed to launch collector healthcheck: \(error.localizedDescription))"]
        }

        var timedOut = false
        let timeoutTimer = DispatchSource.makeTimerSource()
        timeoutTimer.schedule(deadline: .now() + 15)
        timeoutTimer.setEventHandler {
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        timeoutTimer.resume()

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        timeoutTimer.cancel()

        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        guard !stdoutText.isEmpty else {
            return ["(collector healthcheck produced no output, exit code \(process.terminationStatus))"]
        }
        var resultLines = stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if timedOut {
            resultLines.append("(healthcheck timed out after 15s and was terminated — the report above may be incomplete)")
        }
        if let stderrText = String(data: stderrData, encoding: .utf8), !stderrText.isEmpty {
            resultLines.append("")
            resultLines.append("-- healthcheck 探测期间产生的原始日志(通常是探测曲触发的网络审计行,非结构化报告本体) --")
            resultLines.append(contentsOf: collapseRepeatedLines(
                stderrText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        return resultLines
    }

    @MainActor
    private static func currentTrackLyricsLines() -> [String]? {
        let coordinator = PlaybackCoordinator.shared
        let track = (artist: coordinator.artist, title: coordinator.title, album: coordinator.album)
        guard !track.artist.isEmpty || !track.title.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("Track: \(track.artist) — \(track.title)" + (track.album.isEmpty ? "" : " (\(track.album))"))
        guard let key = EnrichCacheReader.resolvedKey(artist: track.artist, title: track.title, album: track.album) else {
            lines.append("Cache: no entry found (never resolved yet, or the normalized key doesn't match — see 第 11 章 known issues)")
            return lines
        }
        lines.append("Cache key: \(key)")
        if let source = EnrichCacheReader.sourceInfo(artist: track.artist, title: track.title, album: track.album) {
            lines.append("Lyrics source: \(source.lyricsSource ?? "(none)")  |  Cover source: \(source.coverSource ?? "(none)")")
        }
        if let lyrics = EnrichCacheReader.lookup(artist: track.artist, title: track.title, album: track.album) {
            lines.append("Has lyrics: \(!lyrics.lyrics.isEmpty)  |  word-level (YRC): \(!lyrics.lyricsYRC.isEmpty)"
                         + "  |  translation: \(!lyrics.lyricsTr.isEmpty)  |  romanization: \(!lyrics.lyricsRoma.isEmpty)")
            lines.append("Instrumental: \(lyrics.instrumental)  |  resolved: \(lyrics.resolved)")
        }
        return lines
    }
}
