import Foundation

public enum UsageParserError: Error, Equatable {
    case invalidJSON
    case missingMetrics
    case invalidMetric
}

public struct UsageParser: Sendable {
    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 180) {
        self.staleAfter = staleAfter
    }

    public func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)

        let payload: UsagePayload
        do {
            payload = try decoder.decode(UsagePayload.self, from: data)
        } catch {
            throw UsageParserError.invalidJSON
        }

        guard let metrics = payload.metrics, !metrics.isEmpty else {
            throw UsageParserError.missingMetrics
        }

        let parsed = metrics.compactMap { $0.metric }
        guard parsed.count == metrics.count, !parsed.isEmpty else {
            throw UsageParserError.invalidMetric
        }

        guard let newest = parsed.map(\.timestamp).max() else {
            throw UsageParserError.invalidMetric
        }

        let state: UsageState = now.timeIntervalSince(newest) > staleAfter ? .stale : .live
        return UsageSnapshot(
            state: state,
            metrics: parsed,
            sourceStatus: payload.sourceStatus ?? payload.status ?? "OK",
            lastUpdated: newest,
            resetTime: parsed.compactMap(\.resetTime).min(),
            message: payload.message
        )
    }

    private static func decodeDate(decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: seconds)
        }

        let value = try container.decode(String.self)
        if let date = Self.iso8601Formatter(fractionalSeconds: true).date(from: value)
            ?? Self.iso8601Formatter(fractionalSeconds: false).date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
    }

    private static func iso8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private struct UsagePayload: Decodable {
    let metrics: [MetricPayload]?
    let status: String?
    let sourceStatus: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case metrics
        case status
        case sourceStatus
        case sourceStatusSnake = "source_status"
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try container.decodeIfPresent([MetricPayload].self, forKey: .metrics)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        sourceStatus = try container.decodeIfPresent(String.self, forKey: .sourceStatus)
            ?? container.decodeIfPresent(String.self, forKey: .sourceStatusSnake)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

private struct MetricPayload: Decodable {
    let name: String?
    let value: Decimal?
    let unit: String?
    let source: String?
    let timestamp: Date?
    let resetTime: Date?
    let confidence: Double?

    var metric: UsageMetric? {
        guard
            let name,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let value,
            let unit,
            !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let source,
            !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let timestamp,
            let confidence,
            (0...1).contains(confidence)
        else {
            return nil
        }

        return UsageMetric(
            name: name,
            value: value,
            unit: unit,
            source: source,
            timestamp: timestamp,
            resetTime: resetTime,
            confidence: confidence
        )
    }

    enum CodingKeys: String, CodingKey {
        case name
        case value
        case unit
        case source
        case timestamp
        case resetTime
        case resetTimeSnake = "reset_time"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        resetTime = try container.decodeIfPresent(Date.self, forKey: .resetTime)
            ?? container.decodeIfPresent(Date.self, forKey: .resetTimeSnake)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)

        if let decimal = try? container.decodeIfPresent(Decimal.self, forKey: .value) {
            value = decimal
        } else if let string = try? container.decodeIfPresent(String.self, forKey: .value) {
            value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        } else {
            value = nil
        }
    }
}
