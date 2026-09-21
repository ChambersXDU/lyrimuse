import Foundation

var failures = 0

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ label: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    guard actual != expected else { return }
    failures += 1
    let location = label.isEmpty ? "\(file):\(line)" : "\(label) (\(file):\(line))"
    print("FAIL - \(location)\n    actual:   \(actual)\n    expected: \(expected)")
}
