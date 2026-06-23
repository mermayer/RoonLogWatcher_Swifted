import AppKit
import RoonLogWatcherCore
import UserNotifications

final class StatusBarController {
    private let store: RuntimeStore
    private let server: DashboardServer
    private let tailer: LogTailer
    private let demoFeed: DemoLogFeed
    private let discoverer: RoonLogDiscoverer
    private let configStore: AppConfigStore
    private let systemSampler = LocalSystemSampler()
    private let statusItem: NSStatusItem
    private var statusTimer: Timer?
    private let menuRefreshInterval: TimeInterval = 5
    private let systemSampleInterval: TimeInterval = 30
    private let openFileSampleInterval: TimeInterval = 120
    private var lastSystemSampleAt = Date.distantPast
    private var lastOpenFileSampleAt = Date.distantPast
    private var lastSystemStatus: LocalSystemStatus?
    private var lastObservedHealthState: RoonHealthState?
    private var isWatching = false

    init(
        store: RuntimeStore,
        server: DashboardServer,
        tailer: LogTailer,
        demoFeed: DemoLogFeed,
        discoverer: RoonLogDiscoverer,
        configStore: AppConfigStore
    ) {
        self.store = store
        self.server = server
        self.tailer = tailer
        self.demoFeed = demoFeed
        self.discoverer = discoverer
        self.configStore = configStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }

    func start() {
        configureStatusItem()
        requestNotificationPermissionIfNeeded()
        sampleSystem(force: true)
        refreshMenu()
        startWatching()
        openDashboard()
        statusTimer = Timer.scheduledTimer(withTimeInterval: menuRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshMenu()
        }
    }

    func stop() {
        statusTimer?.invalidate()
        tailer.stop()
        demoFeed.stop()
        server.stop()
    }

    func reloadConfigAndRestartWatching() {
        configStore.reload()
        stopWatching()
        startWatching()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.squareLength
        button.image = Self.statusIcon()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = "Roon Log Watcher"
    }

    private static func statusIcon() -> NSImage? {
        let symbolNames = [
            "doc.text.magnifyingglass",
            "list.bullet.rectangle.portrait",
            "text.magnifyingglass",
            "doc.text"
        ]
        for symbolName in symbolNames {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Roon Log Watcher") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    private func startWatching() {
        let system = sampleSystem(force: true)
        let started = tailer.start()
        isWatching = started
        if started {
            store.setWatchedFiles(tailer.currentFiles)
            demoFeed.stop()
            store.recordSystemMessage(
                severity: .info,
                title: menuText(en: "Live mode active", de: "Live-Modus aktiv"),
                message: menuText(
                    en: "Roon log files were discovered and are being watched.",
                    de: "Roon-Logdateien wurden gefunden und werden live überwacht."
                )
            )
        } else if system.host.isRoonServerLikely {
            store.setWatchedFiles([])
            demoFeed.stop()
            store.setMode(.idle)
            store.recordSystemMessage(
                severity: .warning,
                title: menuText(en: "Roon Server detected", de: "Roon Server erkannt"),
                message: menuText(
                    en: "This Mac looks like a Roon Server host, but no readable log file was found. Demo mode was not started.",
                    de: "Dieser Mac sieht nach einem Roon-Server-System aus, aber es wurde keine lesbare Logdatei gefunden. Der Demo-Modus wurde nicht gestartet."
                )
            )
        } else if configStore.configuration.enableDemoModeWhenNoLogs {
            store.setWatchedFiles([])
            demoFeed.start()
            store.recordSystemMessage(
                severity: .info,
                title: menuText(en: "Demo feed active", de: "Demo-Feed aktiv"),
                message: menuText(
                    en: "No Roon log directory was discovered. Synthetic runtime events are being streamed.",
                    de: "Es wurde kein Roon-Logverzeichnis gefunden. Es werden synthetische Laufzeitereignisse gestreamt."
                )
            )
        } else {
            store.setWatchedFiles([])
            store.setMode(.idle)
            store.recordSystemMessage(
                severity: .warning,
                title: menuText(en: "No Roon logs found", de: "Keine Roon-Logs gefunden"),
                message: menuText(
                    en: "Demo mode is disabled. Add logDirectories in config.json or enable auto discovery.",
                    de: "Der Demo-Modus ist deaktiviert. Füge logDirectories in config.json hinzu oder aktiviere die automatische Suche."
                )
            )
        }
        refreshMenu()
    }

    private func stopWatching() {
        tailer.stop()
        demoFeed.stop()
        isWatching = false
        store.setMode(.idle)
        refreshMenu()
    }

    private func refreshMenu() {
        sampleSystem(force: false)
        let summary = store.statusSummary()
        notifyIfHealthChanged(summary.health)
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Roon Log Watcher", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        var statusParts = [
            localizedMode(summary.mode),
            "\(menuText(en: "Health", de: "Zustand")) \(summary.healthScore)/100"
        ]
        if let url = server.url {
            statusParts.append("Port \(url.port ?? 0)")
        }
        let statusMenuItem = NSMenuItem(title: shortTitle(statusParts.joined(separator: " · ")), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let currentSourceCount = summary.health.signals.first { $0.id == "source.active" || $0.id == "source.archived_only" }?.count ?? summary.counters.watchedFileCount
        let countersTitle = "\(currentSourceCount) \(menuText(en: "current sources", de: "aktuelle Quellen")) · \(summary.counters.warningCount) \(menuText(en: "warnings", de: "Warnungen")) · \(summary.counters.criticalCount) \(menuText(en: "errors", de: "Fehler"))"
        let countersItem = NSMenuItem(title: shortTitle(countersTitle), action: nil, keyEquivalent: "")
        countersItem.isEnabled = false
        menu.addItem(countersItem)

        let alertTitle: String
        if let latestAlert = summary.alerts.first {
            alertTitle = "\(localizedSeverity(latestAlert.severity)): \(latestAlert.title) - \(latestAlert.message)"
        } else {
            alertTitle = menuText(en: "No recent alerts", de: "Keine aktuellen Warnungen")
        }
        let alertItem = NSMenuItem(title: shortTitle(alertTitle), action: nil, keyEquivalent: "")
        alertItem.isEnabled = false
        menu.addItem(alertItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: menuText(en: "Open Dashboard", de: "Dashboard öffnen"), action: #selector(openDashboardAction), keyEquivalent: "d", target: self))
        menu.addItem(NSMenuItem(title: menuText(en: "Copy Dashboard URL", de: "Dashboard-URL kopieren"), action: #selector(copyDashboardURLAction), keyEquivalent: "c", target: self))
        menu.addItem(NSMenuItem(title: menuText(en: "Open Config", de: "Config öffnen"), action: #selector(openConfigAction), keyEquivalent: ",", target: self))
        menu.addItem(NSMenuItem(title: menuText(en: "Reveal Config", de: "Config anzeigen"), action: #selector(revealConfigAction), keyEquivalent: "r", target: self))
        menu.addItem(NSMenuItem(title: menuText(en: "Reload Config", de: "Config neu laden"), action: #selector(reloadConfigAction), keyEquivalent: "l", target: self))

        let watchTitle = isWatching || summary.mode == .demo
            ? menuText(en: "Stop Watching", de: "Überwachung stoppen")
            : menuText(en: "Start Watching", de: "Überwachung starten")
        menu.addItem(NSMenuItem(title: watchTitle, action: #selector(toggleWatchingAction), keyEquivalent: "s", target: self))
        menu.addItem(NSMenuItem(title: menuText(en: "Open Log Folder", de: "Log-Ordner öffnen"), action: #selector(openLogFolderAction), keyEquivalent: "o", target: self))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: menuText(en: "Quit", de: "Beenden"), action: #selector(quitAction), keyEquivalent: "q", target: self))

        statusItem.menu = menu
    }

    @discardableResult
    private func sampleSystem(force: Bool) -> LocalSystemStatus {
        let now = Date()
        if !force, now.timeIntervalSince(lastSystemSampleAt) < systemSampleInterval, let current = lastSystemStatus {
            return current
        }
        let includeOpenFiles = now.timeIntervalSince(lastOpenFileSampleAt) >= openFileSampleInterval
        let status = systemSampler.sample(discoverer: discoverer, includeOpenFiles: includeOpenFiles)
        store.updateSystemStatus(status)
        lastSystemSampleAt = now
        if includeOpenFiles {
            lastOpenFileSampleAt = now
        }
        lastSystemStatus = status
        return status
    }

    private func requestNotificationPermissionIfNeeded() {
        guard configStore.configuration.sendMacNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfHealthChanged(_ health: RoonHealth) {
        let current = health.state
        guard let previous = lastObservedHealthState else {
            lastObservedHealthState = current
            return
        }
        guard previous != current else { return }
        lastObservedHealthState = current
        guard configStore.configuration.sendMacNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = menuText(en: "Roon Health: \(localizedHealthState(current))", de: "Roon Health: \(localizedHealthState(current))")
        content.body = health.summary
        content.sound = current == .critical ? .defaultCritical : .default
        let request = UNNotificationRequest(
            identifier: "roon-health-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func openDashboard() {
        guard let url = server.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openDashboardAction() {
        openDashboard()
    }

    @objc private func copyDashboardURLAction() {
        guard let url = server.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func toggleWatchingAction() {
        if isWatching || store.statusSummary().mode == .demo {
            stopWatching()
        } else {
            startWatching()
        }
    }

    @objc private func openConfigAction() {
        NSWorkspace.shared.open(configStore.configURL)
    }

    @objc private func revealConfigAction() {
        NSWorkspace.shared.activateFileViewerSelecting([configStore.configURL])
    }

    @objc private func reloadConfigAction() {
        reloadConfigAndRestartWatching()
    }

    @objc private func openLogFolderAction() {
        if let directory = discoverer.discoverDirectories().first {
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    private func shortTitle(_ title: String) -> String {
        if title.count <= 44 { return title }
        return String(title.prefix(41)) + "..."
    }

    private func menuText(en: String, de: String) -> String {
        configStore.configuration.language == .german ? de : en
    }

    private func localizedMode(_ mode: RuntimeMode) -> String {
        switch mode {
        case .idle:
            return menuText(en: "Idle", de: "Inaktiv")
        case .live:
            return menuText(en: "Live logs", de: "Live-Logs")
        case .demo:
            return menuText(en: "Demo feed", de: "Demo-Feed")
        }
    }

    private func localizedSeverity(_ severity: Severity) -> String {
        switch severity {
        case .info:
            return menuText(en: "Info", de: "Info")
        case .warning:
            return menuText(en: "Warning", de: "Warnung")
        case .critical:
            return menuText(en: "Error", de: "Fehler")
        }
    }

    private func localizedHealthState(_ state: RoonHealthState) -> String {
        switch state {
        case .healthy:
            return menuText(en: "Stable", de: "Stabil")
        case .degraded:
            return menuText(en: "Needs attention", de: "Auffällig")
        case .critical:
            return menuText(en: "Critical", de: "Kritisch")
        case .unknown:
            return menuText(en: "Unknown", de: "Unbekannt")
        }
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
