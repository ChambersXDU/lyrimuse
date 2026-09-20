import Foundation
import NaturalLanguage

#if canImport(Translation)
    import Translation
#endif

struct Input: Decodable {
    let target: String
    let lines: [String]
}

struct Output: Encodable {
    var ok: Bool
    var source: String?
    var lines: [String]?
    var reason: String?
}

func emit(_ out: Output) -> Never {
    if let data = try? JSONEncoder().encode(out), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(out.ok ? 0 : 1)
}

func detectSourceLanguage(_ lines: [String]) -> String? {
    let sample = lines.prefix(40).joined(separator: "\n")
    guard !sample.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    return recognizer.dominantLanguage?.rawValue
}

@main
struct LyricsTranslate {
    static func main() async {
        guard let data = FileHandle.standardInput.readDataToEndOfFile() as Data?,
            let input = try? JSONDecoder().decode(Input.self, from: data)
        else {
            emit(Output(ok: false, reason: "bad-input"))
        }
        guard !input.lines.isEmpty, !input.target.isEmpty else {
            emit(Output(ok: false, reason: "empty-input"))
        }
        guard let sourceCode = detectSourceLanguage(input.lines) else {
            emit(Output(ok: false, reason: "undetected-source"))
        }

        if input.target.hasPrefix(sourceCode) || sourceCode.hasPrefix(String(input.target.prefix(2))) {
            emit(Output(ok: false, source: sourceCode, reason: "same-language"))
        }

        #if canImport(Translation)
            guard #available(macOS 26.0, *) else {

                emit(Output(ok: false, source: sourceCode, reason: "needs-macos-26"))
            }
            let source = Locale.Language(identifier: sourceCode)
            let target = Locale.Language(identifier: input.target)

            let status = await LanguageAvailability().status(from: source, to: target)
            guard status == .installed else {

                emit(Output(ok: false, source: sourceCode, reason: "\(status)"))
            }
            let session = TranslationSession(installedSource: source, target: target)
            do {
                let requests = input.lines.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)

                guard responses.count == input.lines.count else {
                    emit(Output(ok: false, source: sourceCode, reason: "count-mismatch"))
                }
                emit(Output(ok: true, source: sourceCode, lines: responses.map(\.targetText)))
            } catch {
                emit(Output(ok: false, source: sourceCode, reason: "\(error)"))
            }
        #else
            emit(Output(ok: false, source: sourceCode, reason: "no-translation-framework"))
        #endif
    }
}
