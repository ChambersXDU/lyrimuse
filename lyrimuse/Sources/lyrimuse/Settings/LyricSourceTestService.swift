import Foundation
import LyrimuseCore
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-source-test")

final class LyricSourceTestService {
    static let shared = LyricSourceTestService()

    private let processLock = NSLock()
    private var runningProcess: Process?

    func cancelRunning() {
        processLock.lock()
        let process = runningProcess
        runningProcess = nil
        processLock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    enum Status: String, Decodable {
        case ok, warn, fail
    }

    struct Result {
        let source: String
        let status: Status

        let reasonCode: String
        let networkLooksDown: Bool
    }

    enum TestError: LocalizedError {
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let msg): return String(format: L10n.t("测试失败: %@"), msg)
            }
        }
    }

    private static let collectorPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/collector").path

    private init() {}

    func test(
        source: LyricsSource? = nil,
        onUpdate: @escaping @MainActor (Result) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await performTest(source: source, onUpdate: onUpdate)
        } onCancel: {
            cancelRunning()
        }
    }

    private func performTest(
        source: LyricsSource?,
        onUpdate: @escaping @MainActor (Result) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.collectorPath)

            process.environment = LyrimusePaths.collectorProcessEnvironment()
            var arguments = ["test-lyric-sources"]
            if let source {
                arguments.append(contentsOf: ["-source", source.rawValue])
            }
            process.arguments = arguments

            self.cancelRunning()
            self.processLock.lock()
            self.runningProcess = process
            self.processLock.unlock()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            final class Box: @unchecked Sendable {
                var outBuffer = Data()
                var errBuffer = Data()
            }
            let box = Box()
            let readQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.test-lyric-sources.stdout", qos: .utility)
            let readGroup = DispatchGroup()

            @Sendable func drainCompleteLines() {
                while let newlineRange = box.outBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = box.outBuffer.subdata(in: box.outBuffer.startIndex..<newlineRange.lowerBound)
                    box.outBuffer.removeSubrange(box.outBuffer.startIndex..<newlineRange.upperBound)
                    guard !lineData.isEmpty else { continue }
                    guard let raw = try? JSONDecoder().decode(RawTestResult.self, from: lineData) else {
                        logger.error("test-lyric-sources: failed to decode a stdout line, skipping")
                        continue
                    }
                    let result = Result(
                        source: raw.source, status: raw.status, reasonCode: raw.reasonCode,
                        networkLooksDown: raw.networkLooksDown)
                    Task { @MainActor in onUpdate(result) }
                }
            }

            readGroup.enter()
            readQueue.async {
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.outBuffer.append(chunk)
                    drainCompleteLines()
                }
                readGroup.leave()
            }

            let stderrQueue = DispatchQueue(label: "me.yudaotor.lyrimuse.test-lyric-sources.stderr", qos: .utility)
            readGroup.enter()
            stderrQueue.async {
                box.errBuffer = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.terminationHandler = { proc in
                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    let msg = String(data: box.errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.error("test-lyric-sources exited \(proc.terminationStatus): \(msg ?? "", privacy: .public)")
                    continuation.resume(throwing: TestError.processFailed(msg?.isEmpty == false ? msg! : String(format: L10n.t("退出码 %@"), "\(proc.terminationStatus)")))
                    return
                }
                continuation.resume(returning: ())
            }

            do {
                try process.run()
            } catch {

                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                continuation.resume(throwing: TestError.processFailed(error.localizedDescription))
            }
        }
    }
}

private struct RawTestResult: Decodable {
    let source: String
    let status: LyricSourceTestService.Status
    let reasonCode: String
    let networkLooksDown: Bool
}
