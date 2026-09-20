import Foundation

public enum LaunchdJobState: Equatable, Sendable {

    case notRegistered

    case running(pid: Int32)

    case registeredNotRunning(lastExitCode: Int32?)

    case unknown

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

extension LaunchdJobState: CustomStringConvertible {

    public var description: String {
        switch self {
        case .notRegistered:
            return "not registered"
        case .running(let pid):
            return "running (pid \(pid))"
        case .registeredNotRunning(let code):
            guard let code else { return "registered but not running (never exited)" }
            return "registered but not running (last exit code \(code))"
        case .unknown:
            return "unknown (launchctl print output not recognized)"
        }
    }
}

public enum LaunchdPrintParser {

    public static func parse(printExitCode: Int32, printOutput: String) -> LaunchdJobState {
        guard printExitCode == 0 else { return .notRegistered }

        var stateValue: String?
        var pid: Int32?
        var lastExitCode: Int32?
        var sawLastExitCodeField = false

        for line in printOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            if let v = topLevelValue(of: "state", in: line) {
                stateValue = v
            } else if let v = topLevelValue(of: "pid", in: line) {
                pid = Int32(v)
            } else if let v = topLevelValue(of: "last exit code", in: line) {
                sawLastExitCodeField = true
                lastExitCode = parseExitCode(v)
            }
        }

        switch stateValue {
        case "running":

            return .running(pid: pid ?? 0)
        case "not running", "waiting":
            return .registeredNotRunning(lastExitCode: sawLastExitCodeField ? lastExitCode : nil)
        case .some:
            return .unknown
        case nil:
            return .unknown
        }
    }

    private static func parseExitCode(_ raw: String) -> Int32? {
        let head = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        return Int32(head.trimmingCharacters(in: .whitespaces))
    }

    private static func topLevelValue(of key: String, in line: Substring) -> String? {
        let prefix = "\t\(key) = "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
