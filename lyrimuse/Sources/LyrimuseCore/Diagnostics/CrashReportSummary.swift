import Foundation

public struct CrashReportSummary: Equatable {
    public struct Frame: Equatable {
        public var imageName: String?
        public var symbol: String?
        public var imageOffset: Int?
        public var sourceFile: String?
        public var sourceLine: Int?

        public init(imageName: String? = nil, symbol: String? = nil, imageOffset: Int? = nil,
                    sourceFile: String? = nil, sourceLine: Int? = nil) {
            self.imageName = imageName
            self.symbol = symbol
            self.imageOffset = imageOffset
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
        }
    }

    public static let maxFrames = 15

    public var fileName: String
    public var processName: String?
    public var processPath: String?
    public var bundleIdentifier: String?
    public var version: String?
    public var buildVersion: String?
    public var bugType: String?
    public var timestamp: String?
    public var osVersion: String?
    public var exceptionType: String?
    public var exceptionSignal: String?
    public var terminationNamespace: String?
    public var terminationIndicator: String?
    public var terminationReasons: [String] = []
    public var terminationDetails: [String] = []
    public var faultingThreadIndex: Int?
    public var frames: [Frame] = []
    public var totalFrames = 0

    public var parseNotes: [String] = []

    public init(fileName: String) {
        self.fileName = fileName
    }

    public static func parse(fileName: String, data: Data) -> CrashReportSummary? {
        guard !data.isEmpty else { return nil }

        var header: [String: Any]?
        var body: [String: Any]?
        if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            header = parseObject(Data(data[data.startIndex..<newline]))
            body = parseObject(Data(data[data.index(after: newline)...]))
            if header == nil && body == nil {

                body = parseObject(data)
            }
        } else if let single = parseObject(data) {

            if looksLikeBody(single) { body = single } else { header = single }
        }
        guard header != nil || body != nil else { return nil }

        var summary = CrashReportSummary(fileName: fileName)
        if header == nil { summary.parseNotes.append("header unreadable") }
        if body == nil { summary.parseNotes.append("body unreadable") }

        if let header {
            summary.processName = header["app_name"] as? String
            summary.version = header["app_version"] as? String
            summary.buildVersion = header["build_version"] as? String
            summary.bugType = stringish(header["bug_type"])
            summary.timestamp = header["timestamp"] as? String
            summary.osVersion = header["os_version"] as? String
            summary.bundleIdentifier = header["bundleID"] as? String
        }
        if let body {
            summary.processName = (body["procName"] as? String) ?? summary.processName
            summary.processPath = body["procPath"] as? String
            if let info = body["bundleInfo"] as? [String: Any] {
                summary.bundleIdentifier = (info["CFBundleIdentifier"] as? String) ?? summary.bundleIdentifier
                summary.version = (info["CFBundleShortVersionString"] as? String) ?? summary.version
                summary.buildVersion = (info["CFBundleVersion"] as? String) ?? summary.buildVersion
            }
            if summary.bugType == nil { summary.bugType = stringish(body["bug_type"]) }
            if summary.timestamp == nil { summary.timestamp = body["captureTime"] as? String }
            if summary.osVersion == nil, let os = body["osVersion"] as? [String: Any] {
                let parts = [os["train"] as? String, (os["build"] as? String).map { "(\($0))" }].compactMap { $0 }
                if !parts.isEmpty { summary.osVersion = parts.joined(separator: " ") }
            }
            if let exception = body["exception"] as? [String: Any] {
                summary.exceptionType = exception["type"] as? String
                summary.exceptionSignal = exception["signal"] as? String
            }
            if let termination = body["termination"] as? [String: Any] {
                summary.terminationNamespace = termination["namespace"] as? String
                summary.terminationIndicator = termination["indicator"] as? String
                summary.terminationReasons = stringList(termination["reasons"])
                summary.terminationDetails = stringList(termination["details"])
            }
            let faulting = intish(body["faultingThread"])
            summary.faultingThreadIndex = faulting
            let images = (body["usedImages"] as? [[String: Any]]) ?? []
            if let threads = body["threads"] as? [[String: Any]], let index = faulting,
               index >= 0, index < threads.count,
               let rawFrames = threads[index]["frames"] as? [[String: Any]] {
                summary.totalFrames = rawFrames.count
                summary.frames = rawFrames.prefix(maxFrames).map { raw in
                    var frame = Frame()
                    if let imageIndex = intish(raw["imageIndex"]), imageIndex >= 0, imageIndex < images.count {
                        frame.imageName = images[imageIndex]["name"] as? String
                    }
                    frame.symbol = raw["symbol"] as? String
                    frame.imageOffset = intish(raw["imageOffset"])
                    frame.sourceFile = raw["sourceFile"] as? String
                    frame.sourceLine = intish(raw["sourceLine"])
                    return frame
                }
            }
        }
        return summary
    }

    private static func looksLikeBody(_ object: [String: Any]) -> Bool {
        object["procName"] != nil || object["threads"] != nil || object["termination"] != nil
    }

    private static func parseObject(_ data: Data) -> [String: Any]? {
        guard data.contains(where: { $0 > 0x20 }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringish(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intish(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { stringish($0) } }
        if let single = stringish(value) { return [single] }
        return []
    }

    public func belongsToApp(executableName: String, bundleIdentifier: String, appDisplayName: String) -> Bool {
        guard let name = processName?.lowercased(),
              name == executableName.lowercased() || name == "collector" else { return false }
        if let id = self.bundleIdentifier, id != bundleIdentifier { return false }
        if let path = processPath, !path.contains("/\(appDisplayName).app/Contents/") { return false }
        return true
    }

    public static func select(_ reports: [CrashReportSummary], perProcessLimit: Int) -> [CrashReportSummary] {
        var byProcess: [String: [CrashReportSummary]] = [:]
        for report in reports {
            byProcess[report.processName?.lowercased() ?? "?", default: []].append(report)
        }
        var out: [CrashReportSummary] = []
        for key in byProcess.keys.sorted() {
            let sorted = byProcess[key]!.sorted { ($0.timestamp ?? $0.fileName) > ($1.timestamp ?? $1.fileName) }
            out.append(contentsOf: sorted.prefix(max(0, perProcessLimit)))
        }
        return out
    }

    public func renderLines() -> [String] {
        var out: [String] = []
        out.append("- \(fileName)")
        var head: [String] = []
        if let timestamp { head.append("time: \(timestamp)") }
        var process = processName ?? "?"
        if let version {
            process += " \(version)"
            if let buildVersion, buildVersion != version { process += " (\(buildVersion))" }
        }
        head.append("process: \(process)")
        if let bugType { head.append("bug_type: \(bugType)") }
        if let osVersion { head.append("os: \(osVersion)") }
        out.append("  " + head.joined(separator: " · "))
        if let processPath { out.append("  path: \(processPath)") }
        if let bundleIdentifier { out.append("  bundle: \(bundleIdentifier)") }
        if exceptionType != nil || exceptionSignal != nil {
            out.append("  exception: " + [exceptionType, exceptionSignal].compactMap { $0 }.joined(separator: " · "))
        }
        if terminationNamespace != nil || terminationIndicator != nil {
            out.append("  termination: " + [terminationNamespace, terminationIndicator].compactMap { $0 }.joined(separator: " · "))
        }
        for reason in terminationReasons { out.append("  reason: \(reason)") }
        for detail in terminationDetails { out.append("  detail: \(detail)") }
        if let index = faultingThreadIndex {
            if frames.isEmpty {
                out.append("  faulting thread \(index): no frames recorded")
            } else {
                out.append("  faulting thread \(index): showing \(frames.count) of \(totalFrames) frames")
                for (position, frame) in frames.enumerated() {
                    var line = String(format: "    %2d  ", position) + (frame.imageName ?? "?")
                    if let symbol = frame.symbol { line += "  \(symbol)" }
                    if let offset = frame.imageOffset { line += " + \(offset)" }
                    if let file = frame.sourceFile {
                        line += "  (\(file)" + (frame.sourceLine.map { ":\($0)" } ?? "") + ")"
                    }
                    out.append(line)
                }
            }
        }
        if !parseNotes.isEmpty { out.append("  note: " + parseNotes.joined(separator: "; ")) }
        return out
    }
}
