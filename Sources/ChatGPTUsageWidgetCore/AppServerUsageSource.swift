import Foundation

public struct UsageLimitWindow: Equatable, Sendable {
    public let key: String
    public let limitId: String
    public let limitName: String
    public let windowName: String
    public let shortName: String
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date

    public var remainingPercent: Int {
        Int(max(0, min(100, 100 - usedPercent)).rounded())
    }

    public var menuTitle: String {
        "\(limitName) · \(windowName) — \(remainingPercent)% remaining"
    }

    public var statusTitle: String {
        "\(remainingPercent)%"
    }
}

public struct UsageLimitsSnapshot: Sendable {
    public let windows: [UsageLimitWindow]
    public let message: String?

    public static func unavailable(_ message: String) -> UsageLimitsSnapshot {
        UsageLimitsSnapshot(windows: [], message: message)
    }

    public func preservingLastKnownWindows(_ previous: [UsageLimitWindow]) -> UsageLimitsSnapshot {
        guard windows.isEmpty, !previous.isEmpty else { return self }
        return UsageLimitsSnapshot(windows: previous, message: message)
    }
}

public enum UsageLimitsParserError: Error, Equatable {
    case invalidResponse
    case noLimits
}

public enum UsageLimitsParser {
    public static func parse(_ data: Data) throws -> [UsageLimitWindow] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageLimitsParserError.invalidResponse
        }

        guard
            let envelope = object as? [String: Any],
            let result = envelope["result"] as? [String: Any]
        else {
            throw UsageLimitsParserError.invalidResponse
        }

        var buckets = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        if buckets.isEmpty,
           let legacy = result["rateLimits"] as? [String: Any],
           let id = legacy["limitId"] as? String {
            buckets[id] = legacy
        }

        let windows = buckets.flatMap { id, rawBucket -> [UsageLimitWindow] in
            guard let bucket = rawBucket as? [String: Any] else { return [] }
            let displayName = (bucket["limitName"] as? String) ?? (id == "codex" ? "Codex general" : id)
            let shortLabel = id == "codex"
                ? "Codex"
                : (displayName.localizedCaseInsensitiveContains("spark") ? "Spark" : displayName)

            return [("primary", bucket["primary"]), ("secondary", bucket["secondary"])]
                .compactMap { position, rawWindow in
                    guard
                        let window = rawWindow as? [String: Any],
                        let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
                        let duration = (window["windowDurationMins"] as? NSNumber)?.intValue,
                        let reset = (window["resetsAt"] as? NSNumber)?.doubleValue
                    else { return nil }

                    return UsageLimitWindow(
                        key: "\(id):\(position)",
                        limitId: id,
                        limitName: displayName,
                        windowName: durationName(duration),
                        shortName: "\(shortLabel) \(shortDuration(duration))",
                        usedPercent: used,
                        durationMinutes: duration,
                        resetsAt: Date(timeIntervalSince1970: reset)
                    )
                }
        }

        guard !windows.isEmpty else { throw UsageLimitsParserError.noLimits }
        return windows.sorted(by: sortWindows)
    }

    private static func sortWindows(_ lhs: UsageLimitWindow, _ rhs: UsageLimitWindow) -> Bool {
        if lhs.limitId == "codex", rhs.limitId != "codex" { return true }
        if rhs.limitId == "codex", lhs.limitId != "codex" { return false }
        if lhs.limitName != rhs.limitName { return lhs.limitName < rhs.limitName }
        return lhs.durationMinutes < rhs.durationMinutes
    }

    private static func durationName(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 {
            let weeks = minutes / 10_080
            return "\(weeks) week" + (weeks == 1 ? "" : "s")
        }
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return "\(days) day" + (days == 1 ? "" : "s")
        }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }

    private static func shortDuration(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)w" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct AppServerUsageSource: Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func fetch() -> UsageLimitsSnapshot {
        guard let codexPath = codexExecutablePath() else {
            return .unavailable("Codex App Server was not found")
        }

        let initialize = """
        {"method":"initialize","id":1,"params":{"clientInfo":{"name":"chatgpt-usage-widget","title":"ChatGPT Usage Widget","version":"2.0"},"capabilities":{"experimentalApi":true}}}
        """
        let request = """
        {"method":"account/rateLimits/read","id":2,"params":{}}
        """

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "{ printf '%s\\n' \"$2\"; sleep 1; printf '%s\\n' \"$3\"; sleep 2; } | \"$1\" app-server",
            "chatgpt-usage-widget",
            codexPath,
            initialize,
            request
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unavailable("Codex App Server could not be started")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return .unavailable("Codex App Server timed out")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        for line in data.split(separator: 0x0A) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let envelope = object as? [String: Any],
                (envelope["id"] as? NSNumber)?.intValue == 2
            else { continue }

            do {
                return UsageLimitsSnapshot(windows: try UsageLimitsParser.parse(Data(line)), message: nil)
            } catch {
                return .unavailable("Codex returned invalid usage limits")
            }
        }

        return .unavailable("Codex returned no usage limits")
    }

    private func codexExecutablePath() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
