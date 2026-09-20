import Combine
import Foundation
import os

private let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "collector-restart")

@MainActor
public final class CollectorRestartCoordinator: ObservableObject {
    public static let shared = CollectorRestartCoordinator()

    @Published public private(set) var isRestarting = false

    private init() {}

    private static let debounceNanoseconds: UInt64 = 500_000_000

    private var pendingTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    public func requestRestart() async -> Bool {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            isRestarting = true
            pendingTask?.cancel()
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.fire()
            }
        }
    }

    private func fire() async {

        let pending = waiters
        waiters = []
        pendingTask = nil

        let ok = await CollectorControl.restartAndWaitAsync()
        if !ok {
            logger.error("collector restart failed (\(pending.count, privacy: .public) waiter(s))")
        }
        for continuation in pending {
            continuation.resume(returning: ok)
        }

        isRestarting = !waiters.isEmpty
    }
}
