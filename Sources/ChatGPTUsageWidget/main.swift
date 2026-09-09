import AppKit
import ChatGPTUsageWidgetCore
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let refreshInterval: TimeInterval = 60
    private let selectionPreference = "selectedUsageLimitWindow"
    private let usageSource = AppServerUsageSource()
    private var windows: [UsageLimitWindow] = []
    private var message: String?
    private var timer: Timer?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.image = Self.chatGPTStatusImage
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.title = "…"
            button.toolTip = "ChatGPT/Codex usage limits"
        }
        rebuildMenu()
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

    private var selectedKey: String {
        get { UserDefaults.standard.string(forKey: selectionPreference) ?? "codex:primary" }
        set { UserDefaults.standard.set(newValue, forKey: selectionPreference) }
    }

    private var selectedWindow: UsageLimitWindow? {
        windows.first(where: { $0.key == selectedKey })
            ?? windows.first(where: { $0.limitId == "codex" })
            ?? windows.first
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        rebuildMenu()
        let source = usageSource

        Task {
            let snapshot = await Task.detached(priority: .utility) {
                source.fetch()
            }.value

            isRefreshing = false
            windows = snapshot.windows
            message = snapshot.message
            if !windows.contains(where: { $0.key == selectedKey }), let fallback = selectedWindow {
                selectedKey = fallback.key
            }
            updateStatusItem()
            rebuildMenu()
        }
    }

    private func updateStatusItem() {
        guard let selected = selectedWindow else {
            statusItem.button?.title = "—"
            statusItem.button?.toolTip = message ?? "Usage limits unavailable"
            return
        }

        statusItem.button?.title = selected.statusTitle
        statusItem.button?.toolTip = selected.menuTitle
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(.init(title: "Limit shown", action: nil, keyEquivalent: ""))

        if windows.isEmpty {
            menu.addItem(.init(title: message ?? (isRefreshing ? "Loading…" : "Unavailable"), action: nil, keyEquivalent: ""))
        } else {
            for window in windows {
                let item = NSMenuItem(title: window.menuTitle, action: #selector(selectWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = window.key
                item.state = window.key == selectedWindow?.key ? .on : .off
                menu.addItem(item)
            }

            if let selected = selectedWindow {
                menu.addItem(.separator())
                menu.addItem(.init(title: "Resets: \(Self.format(selected.resetsAt))", action: nil, keyEquivalent: ""))
                menu.addItem(.init(title: "Used: \(Int(selected.usedPercent.rounded()))%", action: nil, keyEquivalent: ""))
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(
            title: isRefreshing ? "Refreshing…" : "Refresh",
            action: #selector(refreshFromMenu),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let dashboardItem = NSMenuItem(title: "Open Usage Dashboard", action: #selector(openUsageDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        selectedKey = key
        updateStatusItem()
        rebuildMenu()
    }

    @objc private func refreshFromTimer() { refresh() }
    @objc private func refreshFromMenu() { refresh() }

    @objc private func openUsageDashboard() {
        if let url = URL(string: "https://chatgpt.com/#settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static func format(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let chatGPTStatusImage: NSImage? = {
        var candidates: [URL] = []

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let resources = appURL.appendingPathComponent("Contents/Resources")
            candidates.append(resources.appendingPathComponent("chatgptTemplate.png"))
            candidates.append(resources.appendingPathComponent("chatgptTemplate@2x.png"))
        }

        candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png"))
        candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png"))

        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                image.accessibilityDescription = "ChatGPT"
                return image
            }
        }

        let fallback = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ChatGPT")
        fallback?.size = NSSize(width: 16, height: 16)
        fallback?.isTemplate = true
        return fallback
    }()
}

@main
struct ChatGPTUsageWidgetMain {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
