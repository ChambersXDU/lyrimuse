import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "lyrics-timeline")

public enum LyricTimelineNormalizer {
    public static let maxClampMs = 250

    public static var tailWindowMs: Int { KaraokeFill.lineTailLeadMs + KaraokeFill.minTailFillMs }

    public enum DegradeReason: String, CaseIterable {
        case wordStartDecreased = "word_start_decreased"
        case wordBeforeLine = "word_before_line"
        case wordAfterNextLine = "word_after_next_line"
    }

    public struct Report: Equatable {
        public var clampedToLineStart = 0
        public var clampedBeforeNextLine = 0
        public var degradedLines: [DegradeReason: Int] = [:]
        public init() {}
        public var degradedLineCount: Int { degradedLines.values.reduce(0, +) }
        public var isEmpty: Bool {
            clampedToLineStart == 0 && clampedBeforeNextLine == 0 && degradedLines.isEmpty
        }
    }

    public static func normalize(_ lines: [LyricLineWords]) -> (lines: [LyricLineWords], report: Report) {
        var report = Report()
        var out: [LyricLineWords] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {

            var nextStart: Int? = nil
            if i + 1 < lines.count, lines[i + 1].timeMs > line.timeMs {
                nextStart = lines[i + 1].timeMs
            }
            var words: [LyricWord] = []
            words.reserveCapacity(line.words.count)
            var previousStart: Int? = nil
            var degrade: DegradeReason? = nil
            for w in line.words {
                var start = w.startMs
                let end = w.startMs + max(0, w.durationMs)
                if let previousStart, start < previousStart {
                    degrade = .wordStartDecreased
                    break
                }
                if start < line.timeMs {
                    if line.timeMs - start <= maxClampMs {
                        start = line.timeMs
                        report.clampedToLineStart += 1
                    } else {
                        degrade = .wordBeforeLine
                        break
                    }
                }
                if let nextStart, start >= nextStart {
                    if start - nextStart <= maxClampMs {
                        start = max(line.timeMs, previousStart ?? line.timeMs, nextStart - tailWindowMs)
                        report.clampedBeforeNextLine += 1
                    } else {
                        degrade = .wordAfterNextLine
                        break
                    }
                }
                words.append(LyricWord(startMs: start, durationMs: max(0, end - start), text: w.text))
                previousStart = start
            }
            if let degrade {
                report.degradedLines[degrade, default: 0] += 1
                out.append(degraded(line, nextStart: nextStart))
            } else {
                out.append(LyricLineWords(timeMs: line.timeMs, words: words))
            }
        }
        return (out, report)
    }

    static func degraded(_ line: LyricLineWords, nextStart: Int?) -> LyricLineWords {
        let text = line.words.map(\.text).joined()
        let originalEnd = line.words.map { $0.startMs + max(0, $0.durationMs) }.max() ?? line.timeMs
        let end = nextStart ?? originalEnd
        return LyricLineWords(
            timeMs: line.timeMs,
            words: [LyricWord(startMs: line.timeMs, durationMs: max(0, end - line.timeMs), text: text)])
    }

    public static func logSummary(_ report: Report, track: String) {
        guard !report.isEmpty else { return }
        let reasons = report.degradedLines
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        logger.info("word timeline normalized track=\(track, privacy: .public) clamped_to_line_start=\(report.clampedToLineStart) clamped_before_next_line=\(report.clampedBeforeNextLine) degraded_lines=\(report.degradedLineCount) reasons=\(reasons, privacy: .public)")
    }
}
