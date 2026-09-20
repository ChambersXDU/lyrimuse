import LyrimuseCore
import Foundation

@MainActor
func runUpdateChannelTests() {

    do {
        print("\n== 版本号与构建号 ==")
        typealias V = ReleaseVersion
        expectEqual(V(tag: "v1.6.0")?.buildNumberString, "1.6.0.1000")
        expectEqual(V(tag: "1.6.0")?.displayString, "1.6.0")
        expectEqual(V(tag: "v1.6.0-alpha.3")?.buildNumberString, "1.6.0.3")
        expectEqual(V(tag: "v1.6.0-beta.2")?.buildNumberString, "1.6.0.102")
        expectEqual(V(tag: "v1.6.0-rc.1")?.buildNumberString, "1.6.0.501")
        expectEqual(V(tag: "v1.6.0-beta.2")?.displayString, "1.6.0-beta.2")
        expectEqual(V(tag: "v1.6.0-beta.2")?.isPrerelease, true)
        expectEqual(V(tag: "v1.6.0")?.isPrerelease, false)
        expectEqual(V(tag: "v0.0.0")?.buildNumberString, "0.0.0.1000")
        for bad in ["v1.6", "v1.6.0.1", "v1.6.0-beta", "v1.6.0-beta.0", "v1.6.0-foo.1", "v1.6.0-beta.400",
                    "v1.6.0-rc.500", "v1.6.0-alpha.100", "v01.6.0", "v1.6.0-beta.01", "1.6.0-", "", "dev-abc1234",
                    "v1.6.0-beta.1-extra", "v1.6.0 ", "v1.6.0-BETA.1", "v1.6.0-beta.1000"] {
            expectEqual(V(tag: bad) == nil, true)
        }

        let order = ["v1.5.0", "v1.6.0-alpha.1", "v1.6.0-alpha.99", "v1.6.0-beta.1", "v1.6.0-beta.10",
                     "v1.6.0-rc.1", "v1.6.0", "v1.6.1-alpha.1", "v1.10.0"]
        let parsed = order.compactMap { V(tag: $0) }
        expectEqual(parsed.count, order.count)
        expectEqual(parsed.sorted().map(\.displayString), parsed.map(\.displayString))
        expectEqual(V(tag: "v1.6.0-beta.10")! > V(tag: "v1.6.0-beta.9")!, true)
        expectEqual(V(tag: "v1.6.0")! > V(tag: "v1.6.0-rc.1")!, true)
        expectEqual(V(tag: "v1.6.0") == V(tag: "1.6.0"), true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("lyrimuse/scripts/build-version.sh").path
        expectEqual(FileManager.default.isExecutableFile(atPath: script), true)
        for tag in order + ["v0.0.0", "v2.0.0-rc.499", "v2.0.0-beta.399", "v2.0.0-alpha.99", "1.6.0-beta.2"] {
            let result = ProcessRunner.run("/bin/bash", [script, tag], timeout: 10)
            expectEqual(result?.succeeded, true)
            expectEqual(result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), V(tag: tag)?.buildNumberString)
        }
        for bad in ["v1.6", "v1.6.0-beta", "v1.6.0-foo.1", "v1.6.0-beta.400", "v01.6.0", "v1.6.0-beta.01",
                    "1.6.0.1000", "v1.6.0-BETA.1", ""] {
            let result = ProcessRunner.run("/bin/bash", [script, bad], timeout: 10)
            expectEqual(result?.succeeded, false)
        }
    }

    do {
        print("\n== 测试版频道 ==")
        typealias U = UpdateChannel
        let json = """
        [
          {"tag_name":"v1.6.0-beta.2","prerelease":true,"draft":false},
          {"tag_name":"v1.6.0-beta.3","prerelease":true,"draft":true},
          {"tag_name":"v1.5.0","prerelease":false,"draft":false},
          {"tag_name":"nightly","prerelease":true,"draft":false},
          {"tag_name":"v1.4.0","prerelease":false,"draft":false}
        ]
        """
        let releases = U.parseReleases(Data(json.utf8))
        expectEqual(releases?.count, 5)
        expectEqual(releases?.first, U.Release(tag: "v1.6.0-beta.2", prerelease: true, draft: false))
        expectEqual(U.newestRelease(releases ?? [])?.tag, "v1.6.0-beta.2")
        expectEqual(U.betaFeedURL(releases: releases ?? [])?.absoluteString,
                    "https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0-beta.2/appcast.xml")
        let after = [U.Release(tag: "v1.6.0-beta.2", prerelease: true, draft: false),
                     U.Release(tag: "v1.6.0", prerelease: false, draft: false)]
        expectEqual(U.newestRelease(after)?.tag, "v1.6.0")
        expectEqual(U.betaFeedURL(releases: []), nil)
        expectEqual(U.betaFeedURL(releases: [U.Release(tag: "nightly", prerelease: true, draft: false)]), nil)
        expectEqual(U.parseReleases(Data("{\"tag_name\":\"v1\"}".utf8)) == nil, true)
        expectEqual(U.parseReleases(Data("[{\"prerelease\":true}]".utf8)) == nil, true)
        expectEqual(U.parseReleases(Data("[]".utf8))?.isEmpty, true)
        let now = Date()
        expectEqual(U.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: nil), true)
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-600), retryNotBefore: nil), false)
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(-7200), retryNotBefore: nil), true)
        expectEqual(U.shouldRefresh(now: now, fetchedAt: now.addingTimeInterval(600), retryNotBefore: nil), true)
        expectEqual(U.shouldRefresh(now: now, fetchedAt: nil, retryNotBefore: now.addingTimeInterval(60)), false)
        expectEqual(U.releasesAPIURL.host, "api.github.com")
        expectEqual(U.appcastURL(forTag: "v1.6.0").absoluteString.hasPrefix("https://github.com/Yudaotor/lyrimuse/releases/download/v1.6.0/"), true)

        if ProcessInfo.processInfo.environment["LYRIMUSE_LIVE_GITHUB"] == "1" {
            print("\n== 测试版频道真网核对 ==")
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var payload: Data?
            var request = URLRequest(url: U.releasesAPIURL)
            request.timeoutInterval = 15
            request.setValue("Lyrimuse-selftest", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, _, _ in payload = data; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 20)
            let live = payload.flatMap(U.parseReleases)
            expectEqual((live?.count ?? 0) > 0, true)
            let newest = U.newestRelease(live ?? [])
            expectEqual(newest != nil, true)
        }
    }
}
