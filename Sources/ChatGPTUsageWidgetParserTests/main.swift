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

func testParsesSelectableLimitWindows() throws {
    let json = """
    {"id":2,"result":{"rateLimitsByLimitId":{
      "codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":28,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null},
      "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1800000001},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1800000002}}
    }}}
    """

    let windows = try UsageLimitsParser.parse(Data(json.utf8))
    try expect(
        windows.map(\.key) == ["codex:primary", "codex_bengalfox:primary", "codex_bengalfox:secondary"],
        "Expected general, Spark 5h, and Spark weekly windows"
    )
    try expect(windows.map(\.remainingPercent) == [72, 100, 93], "Expected remaining percentage per window")
    try expect(windows.map(\.statusTitle) == ["72%", "100%", "93%"], "Expected compact percentage-only status titles")
}

func testRejectsUsageResponseWithoutLimits() throws {
    do {
        _ = try UsageLimitsParser.parse(Data("{\"id\":2,\"result\":{}}".utf8))
        throw TestFailure.failed("Expected missing limits to fail")
    } catch let error as UsageLimitsParserError {
        try expect(error == .noLimits, "Expected noLimits, got \(error)")
    }
}

func testReadsLiveAppServerLimits() throws {
    let snapshot = AppServerUsageSource().fetch()
    try expect(snapshot.message == nil, snapshot.message ?? "Expected live App Server limits")
    try expect(snapshot.windows.contains(where: { $0.limitId == "codex" }), "Expected the general Codex limit")
    print("LIVE " + snapshot.windows.map { "\($0.key)=\($0.remainingPercent)%" }.joined(separator: ", "))
}

var tests: [(String, () throws -> Void)] = [
    ("parse complete metric", testParsesCompleteMetricAndPreservesFields),
    ("reject malformed JSON", testRejectsMalformedJSON),
    ("reject missing required fields", testRejectsMetricsMissingRequiredFields),
    ("mark old metrics stale", testMarksOldMetricsStale),
    ("parse selectable limit windows", testParsesSelectableLimitWindows),
    ("reject usage response without limits", testRejectsUsageResponseWithoutLimits)
]

if ProcessInfo.processInfo.environment["CHATGPT_USAGE_WIDGET_LIVE_TEST"] == "1" {
    tests.append(("read live App Server limits", testReadsLiveAppServerLimits))
}

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
