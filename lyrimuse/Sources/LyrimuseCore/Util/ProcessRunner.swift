import Foundation
import Darwin

public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data

        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
        public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> Result? {
        guard let spawned = spawn(executable, arguments: arguments, environment: environment) else {
            return nil
        }

        let readFD = spawned.readFD
        defer { close(readFD) }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline: UInt64?
        if timeout.isFinite {
            let seconds = max(0, timeout)
            let nanos = min(seconds * 1_000_000_000, Double(UInt64.max / 2))
            deadline = start + UInt64(nanos)
        } else {
            deadline = nil
        }

        var output = Data()
        var status: Int32 = 0
        var exited = false
        var pipeClosed = false
        var timedOut = false

        while !exited || !pipeClosed {
            if !pipeClosed {
                pipeClosed = readAvailable(from: readFD, into: &output)
            }
            if !exited { exited = reap(spawned.pid, status: &status, blocking: false) }
            if exited && pipeClosed { break }

            if reached(deadline) {
                timedOut = true
                _ = kill(-spawned.pid, SIGTERM)
                _ = kill(spawned.pid, SIGTERM)

                let graceDeadline = DispatchTime.now().uptimeNanoseconds
                    &+ terminationGraceNanoseconds
                while (!exited || !pipeClosed) && DispatchTime.now().uptimeNanoseconds < graceDeadline {
                    if !pipeClosed {
                        pipeClosed = readAvailable(from: readFD, into: &output)
                    }
                    if !exited { exited = reap(spawned.pid, status: &status, blocking: false) }
                    if !exited || !pipeClosed {
                        waitForReadableData(on: pipeClosed ? -1 : readFD, until: graceDeadline)
                    }
                }

                // SIGTERM is intentionally not sufficient: a command may ignore it,
                // and descendants may keep the pipe open. The process group was made
                // private to this invocation, so SIGKILL cannot affect the caller.
                _ = kill(-spawned.pid, SIGKILL)
                _ = kill(spawned.pid, SIGKILL)
                let reapDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                while !exited && DispatchTime.now().uptimeNanoseconds < reapDeadline {
                    exited = reap(spawned.pid, status: &status, blocking: false)
                    if !exited { usleep(1_000) }
                }
                if !exited {
                    status = SIGKILL
                    // Reap asynchronously if the kernel has not completed termination yet.
                    let pid = spawned.pid
                    DispatchQueue.global(qos: .utility).async {
                        var ignored: Int32 = 0
                        _ = reap(pid, status: &ignored, blocking: true)
                    }
                }
                if !pipeClosed {
                    _ = readAvailable(from: readFD, into: &output)
                }
                break
            }

            waitForReadableData(on: pipeClosed ? -1 : readFD, until: deadline)
        }

        return Result(status: terminationStatus(from: status), stdout: output, timedOut: timedOut)
    }

    private static func spawn(
        _ executable: String,
        arguments: [String],
        environment: [String: String]?
    ) -> SpawnedProcess? {
        var fds = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&fds) == 0 else { return nil }

        let readFD = fds[0]
        let writeFD = fds[1]
        let nullFD = open("/dev/null", O_WRONLY)
        guard nullFD >= 0 else {
            close(readFD)
            close(writeFD)
            return nil
        }

        for fd in [readFD, writeFD, nullFD] {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                close(readFD); close(writeFD); close(nullFD)
                return nil
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(readFD)
            close(writeFD)
            close(nullFD)
            if fileActions != nil { _ = posix_spawn_file_actions_destroy(&fileActions) }
            if attributes != nil { _ = posix_spawnattr_destroy(&attributes) }
            return nil
        }

        defer {
            _ = posix_spawn_file_actions_destroy(&fileActions)
            _ = posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, nullFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&fileActions, readFD) == 0,
              posix_spawn_file_actions_addclose(&fileActions, writeFD) == 0,
              posix_spawn_file_actions_addclose(&fileActions, nullFD) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(readFD)
            close(writeFD)
            close(nullFD)
            return nil
        }

        let strings = [executable] + arguments
        var argv = strings.map { strdup($0) }
        argv.append(nil)
        guard argv.dropLast().allSatisfy({ $0 != nil }) else {
            for pointer in argv { if let pointer { free(pointer) } }
            close(readFD)
            close(writeFD)
            close(nullFD)
            return nil
        }
        defer { for pointer in argv { if let pointer { free(pointer) } } }

        let environmentStrings = environment?.map { "\($0.key)=\($0.value)" }
        var envp = environmentStrings?.map { strdup($0) }
        envp?.append(nil)
        if let envp, !envp.dropLast().allSatisfy({ $0 != nil }) {
            for pointer in envp { if let pointer { free(pointer) } }
            close(readFD)
            close(writeFD)
            close(nullFD)
            return nil
        }
        defer { if let envp { for pointer in envp { if let pointer { free(pointer) } } } }

        var pid: pid_t = 0
        let spawnError: Int32 = argv.withUnsafeBufferPointer { argvBuffer in
            if var envp {
                return envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &pid,
                        argvBuffer.baseAddress!.pointee,
                        &fileActions,
                        &attributes,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
            return posix_spawn(
                &pid,
                argvBuffer.baseAddress!.pointee,
                &fileActions,
                &attributes,
                argvBuffer.baseAddress,
                environ
            )
        }

        close(writeFD)
        close(nullFD)
        guard spawnError == 0 else {
            close(readFD)
            return nil
        }

        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            _ = kill(-pid, SIGKILL)
            var ignoredStatus: Int32 = 0
            _ = reap(pid, status: &ignoredStatus, blocking: true)
            close(readFD)
            return nil
        }

        return SpawnedProcess(pid: pid, readFD: readFD)
    }

    @discardableResult
    private static func readAvailable(from fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: readChunkSize)

        // A continuously writing child must not starve the deadline check.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            return true
        }
        return false
    }

    private static func waitForReadableData(on fd: Int32, until deadline: UInt64?) {
        let waitMilliseconds: Int32
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return }
            let remaining = deadline - now
            waitMilliseconds = Int32(min(
                UInt64(maxPollMilliseconds),
                max(UInt64(1), (remaining + 999_999) / 1_000_000)
            ))
        } else {
            waitMilliseconds = maxPollMilliseconds
        }

        var descriptor = pollfd(
            fd: fd,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        while Darwin.poll(&descriptor, 1, waitMilliseconds) < 0 && errno == EINTR {}
    }

    private static func reached(_ deadline: UInt64?) -> Bool {
        guard let deadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private static func reap(_ pid: pid_t, status: inout Int32, blocking: Bool) -> Bool {
        let options: Int32 = blocking ? 0 : WNOHANG
        while true {
            let result = waitpid(pid, &status, options)
            if result == pid { return true }
            if result == 0 { return false }
            if result < 0 && errno == EINTR { continue }
            return true
        }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let raw = UInt32(bitPattern: waitStatus)
        if raw & 0x7f == 0 { return Int32((raw >> 8) & 0xff) }
        return Int32(raw & 0x7f)
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let readFD: Int32
    }

    private static let readChunkSize = 64 * 1024
    private static let maxPollMilliseconds: Int32 = 20
    private static let terminationGraceNanoseconds: UInt64 = 150_000_000
}
