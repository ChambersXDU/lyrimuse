import Foundation

actor LastfmRateLimiter {
    static let shared = LastfmRateLimiter()

    enum Priority {

        case interactive

        case background
    }

    private static let interval: UInt64 = 250_000_000

    private var fgWaiters: [CheckedContinuation<Void, Never>] = []
    private var bgWaiters: [CheckedContinuation<Void, Never>] = []
    private var pumpTask: Task<Void, Never>?

    private var cooldownUntil: Date = .distantPast

    func acquire(priority: Priority) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            switch priority {
            case .interactive:
                fgWaiters.append(cont)
                lastInteractiveAcquire = Date()
            case .background: bgWaiters.append(cont)
            }
            startPumpIfNeeded()
        }
    }

    private var lastInteractiveAcquire: Date = .distantPast

    func interactiveIdle(for seconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastInteractiveAcquire) >= seconds
    }

    func reportThrottled(cooldown: TimeInterval) {
        let target = Date().addingTimeInterval(cooldown)
        if target > cooldownUntil { cooldownUntil = target }
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        while true {
            let now = Date()
            if cooldownUntil > now {
                let wait = cooldownUntil.timeIntervalSince(now)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            if !fgWaiters.isEmpty {
                fgWaiters.removeFirst().resume()
            } else if !bgWaiters.isEmpty {
                bgWaiters.removeFirst().resume()
            } else {
                pumpTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: Self.interval)
        }
    }
}
