import Foundation

public enum BrowserTabProbeScript {

    public static func build(
        bundleID: String, family: BrowserAutomationPermission.Family,
        hostMarker: String, js: String, eventTimeoutSeconds: Int
    ) -> String {
        let activeTab: String
        let executeActive: String
        let executeTab: String
        switch family {
        case .chromium:
            activeTab = "active tab of window wi"
            executeActive = "execute (active tab of window wi) javascript \"\(js)\""
            executeTab = "execute (tab ti of window wi) javascript \"\(js)\""
        case .safari:
            activeTab = "current tab of window wi"
            executeActive = "do JavaScript \"\(js)\" in current tab of window wi"
            executeTab = "do JavaScript \"\(js)\" in tab ti of window wi"
        }
        return """
        tell application id "\(bundleID)"
            set winCount to count of windows
            repeat with wi from 1 to winCount
                try
                    if (URL of \(activeTab)) contains "\(hostMarker)" then
                        with timeout of \(eventTimeoutSeconds) seconds
                            set r to \(executeActive)
                        end timeout
                        if r does not contain "NOTFOUND" then
                            return r
                        end if
                    end if
                end try
            end repeat
            repeat with wi from 1 to winCount
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    try
                        if (URL of tab ti of window wi) contains "\(hostMarker)" then
                            with timeout of \(eventTimeoutSeconds) seconds
                                set r to \(executeTab)
                            end timeout
                            if r does not contain "NOTFOUND" then
                                return r
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return "NOTFOUND"
        end tell
        """
    }

    public static func run(
        bundleID: String, family: BrowserAutomationPermission.Family,
        hostMarker: String, js: String, eventTimeoutSeconds: Int,
        processTimeout: TimeInterval, label: String
    ) -> String? {
        let source = build(bundleID: bundleID, family: family, hostMarker: hostMarker,
                           js: js, eventTimeoutSeconds: eventTimeoutSeconds)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrimuse-\(label)-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let result = ProcessRunner.run("/usr/bin/osascript", [url.path],
                                             timeout: processTimeout),
              result.succeeded
        else { return nil }
        return result.stdoutText
    }
}
