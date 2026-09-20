import Foundation

public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data

        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
        public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let environment { process.environment = environment }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let flag = TimeoutFlag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.fire()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        return Result(status: process.terminationStatus, stdout: data, timedOut: flag.fired)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
