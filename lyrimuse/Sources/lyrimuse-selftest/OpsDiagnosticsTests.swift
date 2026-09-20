import LyrimuseCore
import Foundation
import Darwin

@MainActor
func runOpsDiagnosticsTests() {

    do {
        print("\n== 诊断日志脱敏 ==")
        typealias R = LogRedactor

        let apiKey = "0123456789abcdef0123456789abcdef"
        let relayToken = "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"
        let secrets = ["listenBrainzToken": apiKey, "stateRelayToken": relayToken]

        let leaky = "2026/08/13 10:00:05 listenBrainz: request failed: Get "
            + "\"https://api.listenbrainz.org/1/submit-listens?user=someone&token=\(apiKey)\""
        let cleaned = R.redactAll(leaky, secrets: secrets)
        expectEqual(cleaned.contains(apiKey), false)
        expectEqual(cleaned.contains("<redacted:listenBrainzToken>"), true)
        expectEqual(cleaned.contains("user=someone"), true)
        expectEqual(cleaned.contains("api.listenbrainz.org"), true)

        let rotated = "Get \"https://api.listenbrainz.org/1/submit-listens?token=deadbeefdeadbeefdeadbeefdeadbeef\""
        expectEqual(R.redactAll(rotated, secrets: [:]).contains("deadbeef"), false)

        let bark = "notify push failed (platform=bark): Post \"https://api.day.app/SECRETDEVICEKEY123/t/b\": timeout"
        expectEqual(R.redactAll(bark, secrets: [:]).contains("SECRETDEVICEKEY123"), false)
        expectEqual(R.redactAll(bark, secrets: [:]).contains("api.day.app"), true)

        let nested = "a=\(relayToken) b=\(relayToken + "SUFFIX")"
        let both = R.redact(nested, secrets: ["short": relayToken, "long": relayToken + "SUFFIX"])
        expectEqual(both.contains("SUFFIX"), false)

        let short = R.redact("platform=bark and the bark failed", secrets: ["notificationPlatform": "bark"])
        expectEqual(short.contains("bark and the bark"), true)

        expectEqual(R.redactAll("nothing sensitive here", secrets: secrets),
                    "nothing sensitive here")
    }

    do {
        print("\n== 跨目录探测备份 ==")
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lyrimuse-backup-probe-\(ProcessInfo.processInfo.processIdentifier)")
        let iCloudish = root.appendingPathComponent("iCloudish/Lyrimuse")
        let dropboxish = root.appendingPathComponent("Dropboxish/Lyrimuse")
        let empty = root.appendingPathComponent("NothingHere/Lyrimuse")
        defer { try? fm.removeItem(at: root) }

        try? fm.createDirectory(at: iCloudish, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dropboxish, withIntermediateDirectories: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)

        let older = iCloudish.appendingPathComponent("Lyrimuse-Config-2026-08-01-120000.json")
        let newer = dropboxish.appendingPathComponent("Lyrimuse-Config-2026-08-13-160000.json")
        try? Data("{}".utf8).write(to: older)
        try? Data("{}".utf8).write(to: newer)

        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: newer.path)

        let hit = BackupDiscovery.latest(in: [iCloudish, empty, dropboxish])
        expectEqual(hit?.url.lastPathComponent, "Lyrimuse-Config-2026-08-13-160000.json")
        expectEqual(hit?.folder.lastPathComponent, "Lyrimuse")
        expectEqual(hit?.folder.path, dropboxish.path)

        let missing = root.appendingPathComponent("DoesNotExist/Lyrimuse")
        let hit2 = BackupDiscovery.latest(in: [missing, iCloudish])
        expectEqual(hit2?.url.lastPathComponent, "Lyrimuse-Config-2026-08-01-120000.json")

        expectEqual(BackupDiscovery.latest(in: [empty, missing]) == nil, true)

        try? Data("{}".utf8).write(to: empty.appendingPathComponent("notes.txt"))
        try? Data("{}".utf8).write(to: empty.appendingPathComponent("other.json"))
        expectEqual(BackupDiscovery.latest(in: [empty]) == nil, true)
    }

    do {
        print("\n== 导入配置的地址校验 ==")
        typealias P = ImportPolicy
        expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me"), true)
        expectEqual(P.isAcceptableRelayURL("https://np.yudaotor.me/"), true)
        expectEqual(P.isAcceptableRelayURL("  https://np.yudaotor.me  "), true)
        expectEqual(P.isAcceptableRelayURL("http://attacker.example.com"), false)
        expectEqual(P.isAcceptableRelayURL("http://localhost:8787"), true)
        expectEqual(P.isAcceptableRelayURL("http://127.0.0.1:8787"), true)
        expectEqual(P.isAcceptableRelayURL("file:///etc/passwd"), false)
        expectEqual(P.isAcceptableRelayURL("javascript:alert(1)"), false)
        expectEqual(P.isAcceptableRelayURL("np.yudaotor.me"), false)
        expectEqual(P.isAcceptableRelayURL("https://"), false)
        expectEqual(P.isAcceptableRelayURL(""), false)
    }

    do {
        print("\n== 凭据文件权限 ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-perm-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try? Data("{}".utf8).write(to: tmp, options: .atomic)
        let plain = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        print("  普通 .atomic 写入的权限: \(String(plain, radix: 8))")

        try? FileManager.default.removeItem(at: tmp)
        try? Data("{}".utf8).writeSecurely(to: tmp)
        let secure = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        expectEqual(secure, 0o600)

        try? Data("{\"a\":1}".utf8).writeSecurely(to: tmp)
        let rewritten = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.posixPermissions]
            as? NSNumber)?.intValue ?? -1
        expectEqual(rewritten, 0o600)
    }

    do {
        print("\n== 配置文件三态读写 ==")
        typealias D = JSONConfigDocument
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("lyrimuse-selftest-cfgdoc-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func perm(_ url: URL) -> Int {
            ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        func isRefused(_ error: Error?) -> Bool {
            if let failure = error as? D.Failure, case .refusedCorruptFile = failure { return true }
            return false
        }

        let fresh = dir.appendingPathComponent("fresh.json")
        var d1 = D.load(url: fresh)
        expectEqual(d1.state, .missing)
        var err1: Error?
        do { try d1.save(fields: ["listenbrainz_token": "t1"], secure: true) } catch { err1 = error }
        expectEqual(err1 == nil, true)
        expectEqual(d1.state, .loaded)
        expectEqual(perm(fresh), 0o600)
        expectEqual(D.load(url: fresh).raw["listenbrainz_token"] as? String, "t1")

        let normal = dir.appendingPathComponent("normal.json")
        try? Data(#"{"api_root":"https://x","listenbrainz_token":"old","player":"apple_music"}"#.utf8).write(to: normal)
        var d2 = D.load(url: normal)
        expectEqual(d2.state, .loaded)
        expectEqual(d2.raw["api_root"] as? String, "https://x")
        try? d2.save(fields: ["listenbrainz_token": "new"], knownKeys: ["listenbrainz_token", "player"], secure: false)
        let reread = D.load(url: normal).raw
        expectEqual(reread["api_root"] as? String, "https://x")
        expectEqual(reread["listenbrainz_token"] as? String, "new")
        expectEqual(reread["player"] == nil, true)
        expectEqual(d2.raw["listenbrainz_token"] as? String, "new")
        expectEqual(d2.merging(fields: ["a": 1]).count, 3)

        let bad = dir.appendingPathComponent("bad.json")
        let badBytes = Data(#"{"listenbrainz_token": "SECRETTOKENVALUE", oops"#.utf8)
        try? badBytes.write(to: bad)
        var d3 = D.load(url: bad)
        expectEqual(d3.isCorrupt, true)
        expectEqual(d3.corruptReason?.contains("SECRETTOKENVALUE") ?? true, false)
        var err3: Error?
        do { try d3.save(fields: ["listenbrainz_token": ""], secure: true) } catch { err3 = error }
        expectEqual(isRefused(err3), true)
        expectEqual(try? Data(contentsOf: bad), badBytes)
        expectEqual(d3.isCorrupt, true)
        expectEqual(perm(bad) == 0o600, false)

        let array = dir.appendingPathComponent("array.json")
        try? Data("[1,2]".utf8).write(to: array)
        expectEqual(D.load(url: array).isCorrupt, true)
        let empty = dir.appendingPathComponent("empty.json")
        try? Data().write(to: empty)
        expectEqual(D.load(url: empty).isCorrupt, true)
        let asDir = dir.appendingPathComponent("dir.json")
        try? fm.createDirectory(at: asDir, withIntermediateDirectories: true)
        expectEqual(D.load(url: asDir).isCorrupt, true)
        expectEqual(D.load(url: asDir).state == .missing, false)
        switch D.parseObject(Data("   \n".utf8)) {
        case .success: expectEqual(true, false)
        case .failure: expectEqual(true, true)
        }
        switch D.parseObject(Data("{}".utf8)) {
        case .success(let obj): expectEqual(obj.isEmpty, true)
        case .failure: expectEqual(true, false)
        }

        for secure in [true, false] {
            let orphan = dir.appendingPathComponent("no-such-dir/orphan.json")
            var d4 = D(url: orphan, raw: ["keep": "me"], state: .loaded)
            var threw = false
            do { try d4.save(fields: ["keep": "changed"], secure: secure) } catch { threw = true }
            expectEqual(threw, true)
            expectEqual(d4.raw["keep"] as? String, "me")
            expectEqual(d4.state, .loaded)
        }

        var d4b = D(url: asDir, raw: ["keep": "me"], state: .loaded)
        var threw4b = false
        do { try d4b.save(fields: ["keep": "changed"], secure: false) } catch { threw4b = true }
        expectEqual(threw4b, true)
        expectEqual(d4b.raw["keep"] as? String, "me")

        var d4c = D.load(url: normal)
        var err4c: Error?
        do { try d4c.save(fields: ["when": Date()], secure: false) } catch { err4c = error }
        expectEqual((err4c as? D.Failure) == .notSerializable, true)
        expectEqual(D.load(url: normal).raw["when"] == nil, true)
        expectEqual(d4c.raw["when"] == nil, true)

        var d5 = D.load(url: normal)
        d5.markCorrupt(reason: "fields do not decode")
        expectEqual(d5.isCorrupt, true)
        var err5: Error?
        do { try d5.save(fields: ["a": "b"], secure: false) } catch { err5 = error }
        expectEqual(isRefused(err5), true)
        var d5m = D(url: fresh, state: .missing)
        d5m.markCorrupt(reason: "x")
        expectEqual(d5m.state, .missing)

        let moved = try? d3.quarantineCorruptFile(now: Date(timeIntervalSince1970: 0))
        expectEqual(moved?.lastPathComponent.hasPrefix("bad.json.corrupt-") ?? false, true)
        expectEqual(fm.fileExists(atPath: bad.path), false)
        expectEqual(moved.flatMap { try? Data(contentsOf: $0) }, badBytes)
        expectEqual(d3.state, .missing)
        var err6: Error?
        do { try d3.save(fields: ["listenbrainz_token": "rebuilt"], secure: true) } catch { err6 = error }
        expectEqual(err6 == nil, true)
        expectEqual(D.load(url: bad).raw["listenbrainz_token"] as? String, "rebuilt")

        try? badBytes.write(to: bad)
        var d6 = D.load(url: bad)
        let moved2 = try? d6.quarantineCorruptFile(now: Date(timeIntervalSince1970: 0))
        expectEqual(moved2 != nil && moved2 != moved, true)
        var d6ok = D.load(url: normal)
        expectEqual((try? d6ok.quarantineCorruptFile()) ?? nil, nil)
        expectEqual(fm.fileExists(atPath: normal.path), true)
    }

    if ProcessInfo.processInfo.environment["LYRIMUSE_REDACT_CHECK"] == "1" {
        print("\n== 诊断脱敏真机校验 ==")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cfgURL = home.appendingPathComponent(".config/lyrimuse/config.json")
        let logURL = home.appendingPathComponent("Library/Logs/lyrimuse.log")

        guard let cfgData = try? Data(contentsOf: cfgURL),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let logText = try? String(contentsOf: logURL, encoding: .utf8) else {
            failures += 1
            print("FAIL - 读不到真实 config.json 或日志,校验没跑成")
            exit(1)
        }

        let window = logText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).suffix(200).joined(separator: "\n")

        let credentialFields = ["listenbrainz_token", "state_relay_token", "bark_url",
                                "dingtalk_sign_secret", "feishu_sign_secret"]
        var secrets: [String: String] = [:]
        for f in credentialFields {
            if let v = cfg[f] as? String, !v.isEmpty { secrets[f] = v }
        }

        let before = secrets.filter { window.contains($0.value) }
        let cleaned = LogRedactor.redactAll(window, secrets: secrets)
        let after = secrets.filter { cleaned.contains($0.value) }

        print("  真实凭据字段数: \(secrets.count)")
        print("  脱敏前出现在导出窗口里的: \(before.count) 项 -> \(before.keys.sorted())")
        expectEqual(after.count, 0)
    }

    do {

        let runningOutput = """
        gui/502/com.lyrimuse.collector = {
        \tactive count = 1
        \tstate = running
        \tpid = 82285
        \tlast exit code = 0
        \tspawn type = daemon
        \tendpoints = {
        \t\t"com.example.socket" = {
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = running
        }
        """
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: runningOutput),
                    .running(pid: 82285))

        let notRunningOutput = """
        gui/502/com.lyrimuse.collector = {
        \tactive count = 0
        \tstate = not running
        \tlast exit code = 78
        }
        """
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: notRunningOutput),
                    .registeredNotRunning(lastExitCode: 78))

        let exitCodeWithName = "gui/502/x = {\n\tstate = not running\n\truns = 1\n\tlast exit code = 78: EX_CONFIG\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: exitCodeWithName),
                    .registeredNotRunning(lastExitCode: 78))

        let neverExited = "gui/502/x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: neverExited),
                    .registeredNotRunning(lastExitCode: nil))

        expectEqual(LaunchdPrintParser.parse(printExitCode: 113, printOutput: ""),
                    .notRegistered)

        let nestedOnly = "gui/502/x = {\n\tendpoints = {\n\t\tstate = active\n\t}\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: nestedOnly),
                    .unknown)

        let jobStateOnly = "gui/502/x = {\n\tjob state = running\n}"
        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: jobStateOnly),
                    .unknown)

        expectEqual(LaunchdPrintParser.parse(printExitCode: 0, printOutput: "完全不认识的输出"),
                    .unknown)

        expectEqual(LaunchdJobState.running(pid: 1).isRunning, true)
        expectEqual(LaunchdJobState.registeredNotRunning(lastExitCode: 78).isRunning, false)
        expectEqual(LaunchdJobState.unknown.isRunning, false)
    }

    do {

        let hello = ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        expectEqual(hello?.status, 0)
        expectEqual(hello?.stdoutText, "hello\n")
        expectEqual(hello?.timedOut, false)
        expectEqual(hello?.succeeded, true)

        let inherited = ProcessRunner.run("/bin/sh", ["-c", "echo \"[$LYRIMUSE_SELFTEST_ENV]\""], timeout: 5)
        expectEqual(inherited?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[]")
        let explicit = ProcessRunner.run(
            "/bin/sh", ["-c", "echo \"[$LYRIMUSE_SELFTEST_ENV]\""], timeout: 5,
            environment: ["LYRIMUSE_SELFTEST_ENV": "on"])
        expectEqual(explicit?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "[on]")

        let failed = ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
        expectEqual(failed?.status, 3)
        expectEqual(failed?.succeeded, false)

        expectEqual(ProcessRunner.run("/nonexistent/binary", [], timeout: 5) == nil, true)

        let started = Date()
        let slept = ProcessRunner.run("/bin/sleep", ["10"], timeout: 1)
        let elapsed = Date().timeIntervalSince(started)
        expectEqual(slept?.timedOut, true)
        expectEqual(slept?.succeeded, false)
        expectEqual(elapsed < 5, true)

        let stubbornStart = Date()
        let stubborn = ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; echo $$; while :; do :; done"], timeout: 0.15)
        expectEqual(stubborn?.timedOut, true)
        expectEqual(stubborn?.status, SIGKILL)
        expectEqual(Date().timeIntervalSince(stubbornStart) < 2, true, "SIGTERM-ignoring command has bounded timeout")
        if let pidText = stubborn?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), let pid = Int32(pidText) {
            expectEqual(kill(pid, 0), -1, "timed-out direct child was reaped")
            expectEqual(errno, ESRCH)
        } else {
            expectEqual(false, true, "stubborn command must emit its pid")
        }

        let inheritedPipeStart = Date()
        let inheritedPipe = ProcessRunner.run("/bin/sh", ["-c", "/bin/sleep 20 & echo parent-exited"], timeout: 0.15)
        expectEqual(inheritedPipe?.timedOut, true)
        expectEqual(inheritedPipe?.stdoutText, "parent-exited\n")
        expectEqual(Date().timeIntervalSince(inheritedPipeStart) < 2, true, "inherited stdout cannot keep the caller waiting")

        let streamStart = Date()
        let stream = ProcessRunner.run("/bin/sh", ["-c", "while :; do printf streaming; done"], timeout: 0.05)
        expectEqual(stream?.timedOut, true)
        expectEqual((stream?.stdout.count ?? 0) > 0, true)
        expectEqual(Date().timeIntervalSince(streamStart) < 2, true, "continuous stdout cannot starve timeout checks")

        let big = ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/yes ABCDEFGH | /usr/bin/head -c 1000000"], timeout: 20)
        expectEqual(big?.stdout.count, 1_000_000)
        expectEqual(big?.timedOut, false)

        let noisy = ProcessRunner.run("/bin/sh", ["-c", "/bin/echo out; /bin/echo err >&2"], timeout: 5)
        expectEqual(noisy?.stdoutText, "out\n")

        let noisyBig = ProcessRunner.run(
            "/bin/sh", ["-c", "/usr/bin/yes ERRORLINE | /usr/bin/head -c 500000 >&2; /bin/echo done"], timeout: 20)
        expectEqual(noisyBig?.stdoutText, "done\n")
        expectEqual(noisyBig?.timedOut, false)
    }

    do {
        print("\n== GitHub star 数 ==")
        typealias G = GitHubStars
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":5,"forks_count":0}"#.utf8)), 5)
        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":0}"#.utf8)), 0)
        expectEqual(G.parseStarCount(Data(#"{"forks_count":3}"#.utf8)), nil)
        expectEqual(G.parseStarCount(Data(#"{"stargazers_count":-1}"#.utf8)), nil)
        expectEqual(G.parseStarCount(Data("not json at all".utf8)), nil)

        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: nil), true)
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-60), retryNotBefore: nil), false)
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-G.refreshTTL - 1), retryNotBefore: nil), true)
        expectEqual(G.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(3600), retryNotBefore: nil), true)
        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(60)), false)
        expectEqual(G.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(-1)), true)

        expectEqual(G.retryDate(now: now, rateLimitReset: "\(Int(now.timeIntervalSince1970) + 120)"),
                    now.addingTimeInterval(120))
        expectEqual(G.retryDate(now: now, rateLimitReset: nil), now.addingTimeInterval(G.failureBackoff))
        expectEqual(G.retryDate(now: now, rateLimitReset: "garbage"), now.addingTimeInterval(G.failureBackoff))
        expectEqual(G.retryDate(now: now, rateLimitReset: "1"), now.addingTimeInterval(G.failureBackoff))
    }

    do {
        print("\n== collector 日志时间戳 ==")
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = 2026; comps.month = 9; comps.day = 5; comps.hour = 1; comps.minute = 2; comps.second = 3
        let cal = Calendar(identifier: .gregorian)
        let expectedSlog = cal.date(from: comps)!.addingTimeInterval(0.456)
        let gotSlog = CollectorLogLine.timestamp(of: "time=2026-09-05T01:02:03.456Z level=INFO msg=\"api call summary\" count=12")
        expectEqual(gotSlog.map { abs($0.timeIntervalSince(expectedSlog)) < 0.001 } ?? false, true)
        comps.day = 4; comps.hour = 15; comps.minute = 49; comps.second = 15
        expectEqual(CollectorLogLine.timestamp(of: "2026/09/04 15:49:15 api call: GET api.listenbrainz.org/1/submit-listens -> 200 (315ms)"),
                    cal.date(from: comps))
        expectEqual(CollectorLogLine.timestamp(of: "Bootstrap failed: 5: Input/output error") == nil, true)
        expectEqual(CollectorLogLine.timestamp(of: "time=garbage level=INFO msg=x") == nil, true)
        expectEqual(CollectorLogLine.timestamp(of: "") == nil, true)
        expectEqual(CollectorLogLine.timestamp(of: "2026/09/04 15:49") == nil, true)
        expectEqual(LogFiles.appStderr.lastPathComponent, "lyrimuse-app.log")
        expectEqual(LogFiles.collector.lastPathComponent, "lyrimuse.log")
    }

    do {
        print("\n== 崩溃报告摘要 ==")
        let prod = LyrimuseIdentity.current

        let otherName = prod.displayName + " Nightly"
        let otherID = prod.bundleIdentifier + ".nightly"
        func ips(_ header: String, _ body: String) -> Data { (header + "\n" + body).data(using: .utf8)! }

        let dyldHeader = """
        {"app_name":"lyrimuse","timestamp":"2026-08-30 18:33:01.00 +0800","app_version":"1.4.0","build_version":"1.4.0","bug_type":"309","os_version":"macOS 27.0 (26A5416b)","bundleID":"\(prod.bundleIdentifier)","incident_id":"AAAA"}
        """
        let dyldBody = """
        {"procName":"lyrimuse","procPath":"/Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse","bundleInfo":{"CFBundleShortVersionString":"1.4.0","CFBundleVersion":"1.4.0","CFBundleIdentifier":"\(prod.bundleIdentifier)"},"captureTime":"2026-08-30 18:33:01.5 +0800","exception":{"type":"EXC_CRASH","signal":"SIGABRT","codes":"0x0, 0x0"},"termination":{"code":1,"flags":518,"namespace":"DYLD","indicator":"Library missing","details":["(terminated at launch; ignore backtrace)"],"reasons":["Library not loaded: @rpath/Example.framework/Versions/A/Example","Referenced from: <UUID> /Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse"]},"faultingThread":0,"threads":[{"id":1,"triggered":true,"frames":[]}],"usedImages":[]}
        """
        let dyld = CrashReportSummary.parse(fileName: "lyrimuse-2026-08-30-183301.ips", data: ips(dyldHeader, dyldBody))
        expectEqual(dyld != nil, true)
        if let dyld {
            expectEqual(dyld.processName, "lyrimuse")
            expectEqual(dyld.version, "1.4.0")
            expectEqual(dyld.bugType, "309")
            expectEqual(dyld.timestamp, "2026-08-30 18:33:01.00 +0800")
            expectEqual(dyld.exceptionSignal, "SIGABRT")
            expectEqual(dyld.terminationNamespace, "DYLD")
            expectEqual(dyld.terminationIndicator, "Library missing")
            expectEqual(dyld.terminationReasons.count, 2)
            expectEqual(dyld.terminationDetails, ["(terminated at launch; ignore backtrace)"])
            expectEqual(dyld.faultingThreadIndex, 0)
            expectEqual(dyld.frames.isEmpty && dyld.totalFrames == 0, true)
            expectEqual(dyld.parseNotes.isEmpty, true)
            let text = dyld.renderLines().joined(separator: "\n")
            expectEqual(text.contains("- lyrimuse-2026-08-30-183301.ips"), true)
            expectEqual(text.contains("process: lyrimuse 1.4.0 ·"), true)
            expectEqual(text.contains("termination: DYLD · Library missing"), true)
            expectEqual(text.contains("reason: Library not loaded: @rpath/Example.framework/Versions/A/Example"), true)
            expectEqual(text.contains("faulting thread 0: no frames recorded"), true)
            expectEqual(dyld.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), true)
            expectEqual(dyld.belongsToApp(executableName: "lyrimuse", bundleIdentifier: otherID, appDisplayName: otherName), false)
        }

        let frameJSON = (0..<20).map { i in
            "{\"imageIndex\":\(i % 2),\"imageOffset\":\(1000 + i),\"symbol\":\"sym\(i)\"" + (i == 0 ? ",\"sourceFile\":\"Foo.swift\",\"sourceLine\":42" : "") + "}"
        }.joined(separator: ",")
        let crashBody = """
        {"procName":"lyrimuse","procPath":"/Applications/\(prod.displayName).app/Contents/MacOS/lyrimuse","bundleInfo":{"CFBundleShortVersionString":"1.5.0","CFBundleVersion":"1.5.0.1000","CFBundleIdentifier":"\(prod.bundleIdentifier)"},"captureTime":"2026-09-06 02:00:00.0 +0800","osVersion":{"train":"macOS 27.0","build":"26A5416b"},"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11","flags":0,"code":11},"faultingThread":1,"threads":[{"frames":[{"imageIndex":1,"imageOffset":5}]},{"triggered":true,"frames":[\(frameJSON)]}],"usedImages":[{"name":"lyrimuse","base":0},{"name":"libswiftCore.dylib","base":0}]}
        """
        let crash = CrashReportSummary.parse(fileName: "lyrimuse-2026-09-06-020000.ips", data: ips("{not json", crashBody))
        expectEqual(crash != nil, true)
        if let crash {
            expectEqual(crash.parseNotes, ["header unreadable"])
            expectEqual(crash.timestamp, "2026-09-06 02:00:00.0 +0800")
            expectEqual(crash.osVersion, "macOS 27.0 (26A5416b)")
            expectEqual(crash.faultingThreadIndex, 1)
            expectEqual(crash.totalFrames, 20)
            expectEqual(crash.frames.count, CrashReportSummary.maxFrames)
            expectEqual(crash.frames[0].imageName, "lyrimuse")
            expectEqual(crash.frames[1].imageName, "libswiftCore.dylib")
            expectEqual(crash.frames[0].sourceFile, "Foo.swift")
            expectEqual(crash.frames[0].sourceLine, 42)
            let text = crash.renderLines().joined(separator: "\n")
            expectEqual(text.contains("process: lyrimuse 1.5.0 (1.5.0.1000)"), true)
            expectEqual(text.contains("exception: EXC_BAD_ACCESS · SIGSEGV"), true)
            expectEqual(text.contains("faulting thread 1: showing 15 of 20 frames"), true)
            expectEqual(text.contains("lyrimuse  sym0 + 1000  (Foo.swift:42)"), true)
            expectEqual(text.contains("sym15"), false)
            expectEqual(text.contains("note: header unreadable"), true)
        }

        let collectorHeader = """
        {"app_name":"collector","timestamp":"2026-09-06 01:00:00.00 +0800","app_version":"???","bug_type":"309","os_version":"macOS 27.0 (26A5416b)","incident_id":"BBBB"}
        """
        let collectorBody = """
        {"procName":"collector","procPath":"/Users/USER/*/\(otherName).app/Contents/Resources/collector","exception":{"type":"EXC_CRASH","signal":"SIGKILL (Code Signature Invalid)"},"termination":{"namespace":"CODESIGNING","indicator":"Launch Constraint Violation","flags":66,"code":4},"faultingThread":0,"threads":[{"frames":[]}]}
        """
        let devCollector = CrashReportSummary.parse(fileName: "collector-2026-09-06-010000.ips", data: ips(collectorHeader, collectorBody))
        expectEqual(devCollector?.bundleIdentifier == nil, true)
        expectEqual(devCollector?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: otherID, appDisplayName: otherName), true)
        expectEqual(devCollector?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), false)
        let foreignBody = """
        {"procName":"collector","procPath":"/Applications/Other.app/Contents/MacOS/collector","termination":{"namespace":"SIGNAL","indicator":"Abort trap: 6"}}
        """
        let foreign = CrashReportSummary.parse(fileName: "collector-2026-09-06-010500.ips", data: ips("{\"app_name\":\"collector\"}", foreignBody))
        expectEqual(foreign?.belongsToApp(executableName: "lyrimuse", bundleIdentifier: prod.bundleIdentifier, appDisplayName: prod.displayName), false)

        let headerOnly = CrashReportSummary.parse(fileName: "x.ips", data: ips(dyldHeader, "garbage {"))
        expectEqual(headerOnly?.parseNotes, ["body unreadable"])
        expectEqual(headerOnly?.processName, "lyrimuse")
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: ips("garbage", "more garbage")) == nil, true)
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: Data()) == nil, true)
        expectEqual(CrashReportSummary.parse(fileName: "x.ips", data: "   \n  \n".data(using: .utf8)!) == nil, true)
        let bodyOnly = CrashReportSummary.parse(fileName: "x.ips", data: crashBody.data(using: .utf8)!)
        expectEqual(bodyOnly?.processName, "lyrimuse")
        expectEqual(bodyOnly?.totalFrames, 20)
        let arrayTop = CrashReportSummary.parse(fileName: "x.ips", data: ips("[1,2]", "[3]"))
        expectEqual(arrayTop == nil, true)

        func stub(_ name: String, _ ts: String) -> CrashReportSummary {
            var s = CrashReportSummary(fileName: "\(name)-\(ts).ips"); s.processName = name; s.timestamp = ts; return s
        }
        let many = (1...5).map { stub("lyrimuse", "2026-09-0\($0) 00:00:00") } + (1...4).map { stub("collector", "2026-09-1\($0) 00:00:00") }
        let picked = CrashReportSummary.select(many, perProcessLimit: 3)
        expectEqual(picked.count, 6)
        expectEqual(picked.filter { $0.processName == "lyrimuse" }.count, 3)
        expectEqual(picked.first { $0.processName == "lyrimuse" }?.timestamp, "2026-09-05 00:00:00")
        expectEqual(picked.first { $0.processName == "collector" }?.timestamp, "2026-09-14 00:00:00")
        expectEqual(CrashReportSummary.select([], perProcessLimit: 3).isEmpty, true)
        expectEqual(CrashReportSummary.select(many, perProcessLimit: 0).isEmpty, true)

        if ProcessInfo.processInfo.environment["LYRIMUSE_LIVE_CRASHREPORTS"] == "1" {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("lyrimuse-") && $0.hasSuffix(".ips") }.sorted()
            print("live: \(names.count) real report(s)")
            for name in names {
                let data = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
                let parsed = CrashReportSummary.parse(fileName: name, data: data)
                expectEqual(parsed != nil, true)
                expectEqual(parsed?.parseNotes.isEmpty, true)
                expectEqual(parsed?.terminationIndicator != nil, true)
            }
            if let last = names.last, let data = try? Data(contentsOf: dir.appendingPathComponent(last)),
               let parsed = CrashReportSummary.parse(fileName: last, data: data) {
                for line in parsed.renderLines() { print("   ", line) }
            }
        }
    }

    do {
        let buildScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        if let text = try? String(contentsOfFile: buildScript.path, encoding: .utf8) {

            let codeLines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
            let adHocLiterals = codeLines.filter { $0.contains("--sign -\"") || $0.contains("-s - ") }
            expectEqual(adHocLiterals, [])
            expectEqual(text.contains("SIGN_ID=\"${LYRIMUSE_SIGN_ID:-}\""), true)
            expectEqual(text.contains("SIGN_ID=\"-\""), true)
            expectEqual(text.contains("DEV_SIGN_NAME=\"Lyrimuse Dev Signing\""), true)
            let signCalls = codeLines.filter { $0.contains("codesign") && $0.contains("$SIGN_ID") }.count
            expectEqual(signCalls >= 8, true)
        } else {
            expectEqual(true, false)
        }
    }

    do {
        let buildScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build.sh")
        if let text = try? String(contentsOfFile: buildScript.path, encoding: .utf8) {

            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            expectEqual(code.contains("OLD_PIDS="), true)
            expectEqual(code.contains("[ \"$pid\" = \"$OLD_PIDS\" ]"), true)
            expectEqual(code.contains("modal sheet"), true)

            if let guardRange = code.range(of: "= \"$OLD_PIDS\" ]"),
               let okRange = code.range(of: "echo \"==> $APP_NAME running, pid") {
                expectEqual(guardRange.lowerBound < okRange.lowerBound, true)
            } else {
                expectEqual(true, false)
            }
        } else {
            expectEqual(true, false)
        }
    }
}
