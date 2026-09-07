import Foundation

public enum UsageState: String, Sendable {
    case live = "LIVE"
    case stale = "STALE"
    case unavailable = "UNAVAILABLE"
    case error = "ERROR"
}

public struct UsageMetric: Equatable, Sendable {
    public let name: String
    public let value: Decimal
    public let unit: String
    public let source: String
    public let timestamp: Date
    public let resetTime: Date?
    public let confidence: Double

    public init(
        name: String,
        value: Decimal,
        unit: String,
        source: String,
        timestamp: Date,
        resetTime: Date?,
        confidence: Double
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.source = source
        self.timestamp = timestamp
        self.resetTime = resetTime
        self.confidence = confidence
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let state: UsageState
    public let metrics: [UsageMetric]
    public let sourceStatus: String
    public let lastUpdated: Date?
    public let resetTime: Date?
    public let message: String?

    public init(
        state: UsageState,
        metrics: [UsageMetric],
        sourceStatus: String,
        lastUpdated: Date?,
        resetTime: Date?,
        message: String?
    ) {
        self.state = state
        self.metrics = metrics
        self.sourceStatus = sourceStatus
        self.lastUpdated = lastUpdated
        self.resetTime = resetTime
        self.message = message
    }

    public static func unavailable(_ message: String = "No authoritative local source reachable") -> UsageSnapshot {
        UsageSnapshot(
            state: .unavailable,
            metrics: [],
            sourceStatus: "Unavailable",
            lastUpdated: nil,
            resetTime: nil,
            message: message
        )
    }

    public static func error(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            state: .error,
            metrics: [],
            sourceStatus: "Error",
            lastUpdated: nil,
            resetTime: nil,
            message: message
        )
    }
}

