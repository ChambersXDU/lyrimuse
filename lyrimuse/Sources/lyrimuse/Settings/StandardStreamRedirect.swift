import Darwin
import Foundation
import LyrimuseCore

enum StandardStreamRedirect {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        guard isatty(STDERR_FILENO) == 0 else { return }
        let url = LogFiles.appStderr
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}
