import Foundation

public struct HelperConfiguration: Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String] = ["--json"]) {
        self.executable = executable
        self.arguments = arguments
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperConfiguration {
        if let path = environment["CHATGPT_USAGE_WIDGET_HELPER"], !path.isEmpty {
            return HelperConfiguration(executable: path, arguments: ["--json"])
        }

        return HelperConfiguration(executable: "chatgpt-usage-helper", arguments: ["--json"])
    }
}

public struct LocalHelperUsageSource: Sendable {
    public let configuration: HelperConfiguration
    public let parser: UsageParser
    public let timeout: TimeInterval

    public init(
        configuration: HelperConfiguration = .fromEnvironment(),
        parser: UsageParser = UsageParser(),
        timeout: TimeInterval = 10
    ) {
        self.configuration = configuration
        self.parser = parser
        self.timeout = timeout
    }

    public func fetch(now: Date = Date()) -> UsageSnapshot {
        guard let executableURL = resolveExecutable(configuration.executable) else {
            return LocalCodexLogUsageSource().fetch(now: now)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = configuration.arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
        } catch {
            return .unavailable("Documented helper could not be started")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return .error("Documented helper timed out")
        }

        guard process.terminationStatus == 0 else {
            return .error("Documented helper exited with status \(process.terminationStatus)")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return .unavailable("Documented helper returned no JSON")
        }

        do {
            return try parser.parse(data, now: now)
        } catch {
            return .unavailable("Documented helper returned invalid usage JSON")
        }
    }

    private func resolveExecutable(_ executable: String) -> URL? {
        if executable.contains("/") {
            let url = URL(fileURLWithPath: executable)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }

        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)

        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}

public struct LocalCodexLogUsageSource: Sendable {
    public let sessionsDirectory: URL
    public let maxFilesToInspect: Int
    public let maxBytesPerFile: UInt64

    public init(
        sessionsDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        maxFilesToInspect: Int = 12,
        maxBytesPerFile: UInt64 = 262_144
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.maxFilesToInspect = maxFilesToInspect
        self.maxBytesPerFile = maxBytesPerFile
    }

    public func fetch(now: Date = Date()) -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
            return .unavailable("Codex session log directory not found")
        }

        do {
            guard let event = try latestRateLimitEvent() else {
                return .unavailable("No Codex rate limit event found in local session logs")
            }

            return snapshot(from: event, now: now)
        } catch {
            return .error("Could not read Codex local usage logs")
        }
    }

    private func latestRateLimitEvent() throws -> CodexRateLimitEvent? {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latest: CodexRateLimitEvent?
        let decoder = Self.decoder
        var candidates: [(url: URL, modified: Date)] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            candidates.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        for fileURL in candidates.sorted(by: { $0.modified > $1.modified }).prefix(maxFilesToInspect).map(\.url) {
            let content = try tailText(from: fileURL)
            for line in content.split(whereSeparator: \.isNewline) {
                guard line.contains("\"token_count\""), line.contains("\"rate_limits\"") else { continue }
                guard let data = String(line).data(using: .utf8) else { continue }
                guard let event = try? decoder.decode(CodexRateLimitEvent.self, from: data) else { continue }
                if latest == nil || event.timestamp > latest!.timestamp {
                    latest = event
                }
            }
        }

        return latest
    }

    private func tailText(from fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        let offset = size > maxBytesPerFile ? size - maxBytesPerFile : 0
        try handle.seek(toOffset: offset)
        return String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func snapshot(from event: CodexRateLimitEvent, now: Date) -> UsageSnapshot {
        let rateLimits = event.payload.rateLimits
        let used = Decimal(rateLimits.primary.usedPercent)
        let remaining = max(Decimal(0), min(Decimal(100), Decimal(100) - used))
        let staleAfter: TimeInterval = 180
        let state: UsageState = now.timeIntervalSince(event.timestamp) > staleAfter ? .stale : .live
        let resetTime = Date(timeIntervalSince1970: rateLimits.primary.resetsAt)
        let limitName = rateLimits.limitName ?? rateLimits.limitId
        let credits = rateLimits.credits?.displayText ?? "credits unavailable"
        let message = "Codex local session logs; \(limitName); \(credits)"

        let metric = UsageMetric(
            name: "\(rateLimits.limitId)_remaining",
            value: remaining,
            unit: "percent",
            source: "codex-local-session-jsonl",
            timestamp: event.timestamp,
            resetTime: resetTime,
            confidence: state == .live ? 0.85 : 0.55
        )

        return UsageSnapshot(
            state: state,
            metrics: [metric],
            sourceStatus: "Codex local session logs",
            lastUpdated: event.timestamp,
            resetTime: resetTime,
            message: message
        )
    }

    private static func decodeDate(decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex event timestamp")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        return decoder
    }()

}

private struct CodexRateLimitEvent: Decodable {
    let timestamp: Date
    let payload: CodexRateLimitPayload
}

private struct CodexRateLimitPayload: Decodable {
    let rateLimits: CodexRateLimits

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct CodexRateLimits: Decodable {
    let limitId: String
    let limitName: String?
    let primary: CodexRateLimitWindow
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case limitId = "limit_id"
        case limitName = "limit_name"
        case primary
        case credits
    }
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

private struct CodexCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    var displayText: String {
        if unlimited { return "unlimited credits" }
        if hasCredits { return "credits \(balance ?? "available")" }
        return "no credits"
    }
}
