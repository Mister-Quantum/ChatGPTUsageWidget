import AppKit
import ChatGPTUsageWidgetCore
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 60
    private lazy var usageSource = LocalHelperUsageSource(parser: UsageParser(staleAfter: refreshInterval * 3))
    private var timer: Timer?
    private var currentSnapshot: UsageSnapshot = .unavailable()
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem.button?.title = "ChatGPT Unavailable"
        statusItem.button?.toolTip = "ChatGPT usage status"

        refresh()
        let timer = Timer.scheduledTimer(
            timeInterval: refreshInterval,
            target: self,
            selector: #selector(refreshFromTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 10
        self.timer = timer
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let source = usageSource
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                source.fetch()
            }.value

            isRefreshing = false
            currentSnapshot = snapshot
            statusItem.button?.title = Self.menuBarTitle(for: snapshot)
            statusItem.menu = makeMenu(for: snapshot)
        }
    }

    @objc private func refreshFromTimer() {
        refresh()
    }

    private func makeMenu(for snapshot: UsageSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.init(title: "State: \(snapshot.state.rawValue)", action: nil, keyEquivalent: ""))
        menu.addItem(.init(title: "Source: \(snapshot.sourceStatus)", action: nil, keyEquivalent: ""))
        menu.addItem(.init(title: "Last Updated: \(Self.format(snapshot.lastUpdated))", action: nil, keyEquivalent: ""))
        menu.addItem(.init(title: "Reset: \(Self.format(snapshot.resetTime))", action: nil, keyEquivalent: ""))

        if let metric = Self.primaryMetric(from: snapshot) {
            menu.addItem(.init(title: "Metric: \(metric.name)", action: nil, keyEquivalent: ""))
            menu.addItem(.init(title: "Value: \(Self.formatMetric(metric))", action: nil, keyEquivalent: ""))
            menu.addItem(.init(title: "Confidence: \(Self.percent(metric.confidence))", action: nil, keyEquivalent: ""))
        } else if let message = snapshot.message {
            menu.addItem(.init(title: message, action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let dashboardItem = NSMenuItem(
            title: "Open Usage Dashboard",
            action: #selector(openUsageDashboard),
            keyEquivalent: "d"
        )
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func openUsageDashboard() {
        if let url = URL(string: "https://chatgpt.com/#settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func menuBarTitle(for snapshot: UsageSnapshot) -> String {
        guard let metric = primaryMetric(from: snapshot) else {
            return "ChatGPT Unavailable"
        }

        switch snapshot.state {
        case .live:
            return "ChatGPT \(formatMetric(metric))"
        case .stale:
            return "ChatGPT Stale \(formatMetric(metric))"
        case .unavailable, .error:
            return "ChatGPT Unavailable"
        }
    }

    private static func primaryMetric(from snapshot: UsageSnapshot) -> UsageMetric? {
        snapshot.metrics.first { metric in
            metric.name.localizedCaseInsensitiveContains("remaining")
        } ?? snapshot.metrics.first
    }

    private static func formatMetric(_ metric: UsageMetric) -> String {
        let value = NSDecimalNumber(decimal: metric.value).doubleValue
        let number: String
        if value.rounded() == value {
            number = String(Int(value))
        } else {
            number = String(format: "%.1f", value)
        }

        switch metric.unit.lowercased() {
        case "percent", "percentage", "%":
            return "\(number)% remaining"
        default:
            return "\(number) \(metric.unit)"
        }
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return dateFormatter.string(from: date)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

@main
struct ChatGPTUsageWidgetMain {
    @MainActor
    private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
