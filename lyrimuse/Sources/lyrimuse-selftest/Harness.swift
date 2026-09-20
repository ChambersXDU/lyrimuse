import Foundation

var failures = 0

var assertions = 0

var quietOutput = false

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1
    if actual == expected {
        if !quietOutput {
            if label.isEmpty {
                print("ok")
            } else {
                print("ok - \(label)")
            }
        }
    } else {
        failures += 1
        let prefix = label.isEmpty ? "FAIL at \(file):\(line)" : "FAIL - \(label)"
        print("\(prefix)\n    actual:   \(actual)\n    expected: \(expected)")
    }
}

func expectNotEqual<T: Equatable>(_ actual: T, _ unexpected: T, _ label: String = "", file: StaticString = #file, line: UInt = #line) {
    assertions += 1
    if actual != unexpected {
        if !quietOutput {
            if label.isEmpty {
                print("ok")
            } else {
                print("ok - \(label)")
            }
        }
    } else {
        failures += 1
        let prefix = label.isEmpty ? "FAIL at \(file):\(line)" : "FAIL - \(label)"
        print("\(prefix)\n    两者相等,但期望不同:  \(actual)")
    }
}
