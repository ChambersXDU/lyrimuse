import Foundation

let transform = StringTransform("Traditional-Simplified")
while let line = readLine(strippingNewline: true) {
    let ch = line.trimmingCharacters(in: .whitespaces)
    guard !ch.isEmpty else { continue }
    let converted = ch.applyingTransform(transform, reverse: false) ?? ch
    print("\(ch)\t\(converted)")
}
