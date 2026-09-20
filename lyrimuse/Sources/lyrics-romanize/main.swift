import Foundation
import LyrimuseCore

struct Input: Decodable {
    let lyrics: String
}

struct Output: Encodable {
    var ok: Bool
    var roma: String?
    var reason: String?
}

func emit(_ out: Output) -> Never {
    if let data = try? JSONEncoder().encode(out), let s = String(data: data, encoding: .utf8) {
        print(s)
    }

    exit(out.ok ? 0 : 1)
}

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
    emit(Output(ok: false, reason: "bad-input"))
}
guard !input.lyrics.isEmpty else {
    emit(Output(ok: false, reason: "empty-input"))
}
guard let roma = LyricsRomanization.romanizeLRC(input.lyrics) else {
    emit(Output(ok: false, reason: "no-romanization"))
}
emit(Output(ok: true, roma: roma))
