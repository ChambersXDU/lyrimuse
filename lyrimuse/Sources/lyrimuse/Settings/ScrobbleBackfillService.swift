import Foundation
import LyrimuseCore
import OSLog

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "backfill")

@MainActor
final class ScrobbleBackfillService: ObservableObject {
    static let shared = ScrobbleBackfillService()

    struct Item: Codable, Equatable, Identifiable {
        var uts: Int64
        var artist: String
        var title: String
        var album: String?
        var dur: Double?
        var id: Int64 { uts }
    }

    struct Outcome: Codable, Equatable {
        var items: [Item] = []
        var eligible = 0
        var accepted = 0
        var ignored = 0
        var skippedTooOld = 0
        var quarantined = 0
        var abortedReason: String?

        private enum CodingKeys: String, CodingKey {
            case items, eligible, accepted, ignored, skippedTooOld, quarantined, abortedReason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            eligible = try c.decodeIfPresent(Int.self, forKey: .eligible) ?? 0
            accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
            ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
            skippedTooOld = try c.decodeIfPresent(Int.self, forKey: .skippedTooOld) ?? 0
            quarantined = try c.decodeIfPresent(Int.self, forKey: .quarantined) ?? 0
            abortedReason = try c.decodeIfPresent(String.self, forKey: .abortedReason)
        }
    }

    @Published private(set) var pending: Outcome?

    @Published private(set) var lastRun: Outcome?

    @Published private(set) var lastRunFailed = false
    @Published private(set) var busy = false

    private init() {}

    private static var collectorPath: String {

        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/collector").path
    }

    static func listenLogModifiedAt() -> Date? {
        let url = LyrimusePaths.configFile("lyrimuse-listens.jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func refreshPending() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let out = await Self.run(dryRun: true)
            pending = out
            busy = false
        }
    }

    func runBackfill() {
        guard !busy else { return }
        busy = true

        lastRun = nil
        lastRunFailed = false
        Task { @MainActor in
            let out = await Self.run(dryRun: false)
            lastRun = out
            lastRunFailed = (out == nil)
            pending = await Self.run(dryRun: true)
            busy = false
            logger.notice("""
                backfill finished: accepted=\(out?.accepted ?? -1, privacy: .public) \
                ignored=\(out?.ignored ?? -1, privacy: .public) \
                quarantined=\(out?.quarantined ?? -1, privacy: .public)
                """)

            if let out, out.accepted > 0 {
                LastfmStatsService.shared.refreshBaseline(force: true)
                LastfmStatsService.shared.rewindDailySyncForBackfill()

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !LastfmStatsService.shared.feedIsFresh {
                        LastfmStatsService.shared.refreshBaseline(force: true)
                    }
                }
            }
        }
    }

    func dismissLastRun() {
        lastRun = nil
        lastRunFailed = false
    }

    func deleteListen(uts: Int64) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await Self.runDelete(uts: uts)

            pending = await Self.run(dryRun: true)
            busy = false
            logger.notice("delete listen uts=\(uts, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    private static func runDelete(uts: Int64) async -> Bool {
        let path = collectorPath
        return await Task.detached(priority: .userInitiated) { () -> Bool in

            guard let r = ProcessRunner.run(
                path, ["delete-listen", "-uts", String(uts)], timeout: 15,
                environment: LyrimusePaths.collectorProcessEnvironment()), r.succeeded
            else { return false }
            struct Result: Decodable { let deleted: Int }
            return (try? JSONDecoder().decode(Result.self, from: r.stdout))?.deleted ?? 0 > 0
        }.value
    }

    private static func run(dryRun: Bool) async -> Outcome? {
        let path = collectorPath
        return await Task.detached(priority: .userInitiated) { () -> Outcome? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)

            process.environment = LyrimusePaths.collectorProcessEnvironment()
            process.arguments = dryRun ? ["backfill-lastfm", "-dry-run"] : ["backfill-lastfm"]
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()

                let deadline: UInt64 = dryRun ? 20 : 15 * 60
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: deadline * 1_000_000_000)
                    if !Task.isCancelled, process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                guard process.terminationStatus == 0 else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    logger.error("backfill exited \(process.terminationStatus, privacy: .public): \(err, privacy: .public)")
                    return nil
                }
                do {
                    return try JSONDecoder().decode(Outcome.self, from: data)
                } catch {

                    logger.error("backfill decode failed dryRun=\(dryRun, privacy: .public): \(String(describing: error), privacy: .public)")
                    return nil
                }
            } catch {
                logger.error("backfill spawn failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }
}
