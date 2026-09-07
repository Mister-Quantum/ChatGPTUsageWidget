import ChatGPTUsageWidgetCore
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

func expectThrows(_ expected: UsageParserError, _ block: () throws -> Void) throws {
    do {
        try block()
        throw TestFailure.failed("Expected \(expected) to be thrown")
    } catch let error as UsageParserError {
        try expect(error == expected, "Expected \(expected), got \(error)")
    }
}

func iso8601Date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}

func testParsesCompleteMetricAndPreservesFields() throws {
    let json = """
    {
      "source_status": "authorized local helper",
      "metrics": [
        {
          "name": "chatgpt_remaining",
          "value": 82.5,
          "unit": "percent",
          "source": "codex-desktop-local-helper",
          "timestamp": "2026-09-07T16:00:00Z",
          "reset_time": "2026-09-08T00:00:00Z",
          "confidence": 0.98
        }
      ]
    }
    """

    let snapshot = try UsageParser(staleAfter: 300).parse(
        Data(json.utf8),
        now: iso8601Date("2026-09-07T16:01:00Z")
    )

    try expect(snapshot.state == .live, "Expected LIVE state")
    try expect(snapshot.sourceStatus == "authorized local helper", "Expected source status to be preserved")
    try expect(snapshot.metrics.count == 1, "Expected exactly one metric")
    try expect(snapshot.metrics[0].name == "chatgpt_remaining", "Expected metric name to be preserved")
    try expect(snapshot.metrics[0].value == Decimal(string: "82.5"), "Expected metric value to be preserved")
    try expect(snapshot.metrics[0].unit == "percent", "Expected unit to be preserved")
    try expect(snapshot.metrics[0].source == "codex-desktop-local-helper", "Expected source to be preserved")
    try expect(snapshot.metrics[0].confidence == 0.98, "Expected confidence to be preserved")
    try expect(snapshot.resetTime == iso8601Date("2026-09-08T00:00:00Z"), "Expected reset time")
}

func testRejectsMalformedJSON() throws {
    try expectThrows(.invalidJSON) {
        _ = try UsageParser().parse(Data("{not-json".utf8))
    }
}

func testRejectsMetricsMissingRequiredFields() throws {
    let json = """
    {"metrics":[{"name":"chatgpt_remaining","value":90,"unit":"percent"}]}
    """

    try expectThrows(.invalidMetric) {
        _ = try UsageParser().parse(Data(json.utf8))
    }
}

func testMarksOldMetricsStale() throws {
    let json = """
    {
      "metrics": [
        {
          "name": "chatgpt_remaining",
          "value": "12",
          "unit": "percent",
          "source": "codex-desktop-local-helper",
          "timestamp": "2026-09-07T16:00:00Z",
          "confidence": 0.9
        }
      ]
    }
    """

    let snapshot = try UsageParser(staleAfter: 60).parse(
        Data(json.utf8),
        now: iso8601Date("2026-09-07T16:03:00Z")
    )

    try expect(snapshot.state == .stale, "Expected STALE state")
}

let tests: [(String, () throws -> Void)] = [
    ("parse complete metric", testParsesCompleteMetricAndPreservesFields),
    ("reject malformed JSON", testRejectsMalformedJSON),
    ("reject missing required fields", testRejectsMetricsMissingRequiredFields),
    ("mark old metrics stale", testMarksOldMetricsStale)
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("All parser tests passed")
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
