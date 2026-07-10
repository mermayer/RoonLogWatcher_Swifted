import AppKit
import RoonLogWatcherCore

@main
@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configStore = AppConfigStore()
        let config = configStore.configuration
        let runtime = RuntimeStore(
            configuration: config,
            memoryInsightStoreURL: configStore.configURL.deletingLastPathComponent().appendingPathComponent("memory-insights.json")
        )
        let parser = LogParser()
        let dashboardServer = DashboardServer(store: runtime, configStore: configStore)
        let discoverer = RoonLogDiscoverer(configStore: configStore)
        let tailer = LogTailer(discoverer: discoverer, configStore: configStore) { file, line in
            let events = parser.parse(file: file, line: line)
            runtime.ingest(file: file, line: line, events: events, mode: .live)
        }
        let demoFeed = DemoLogFeed { file, line in
            let events = parser.parse(file: file, line: line)
            runtime.ingest(file: file, line: line, events: events, mode: .demo)
        }

        do {
            try dashboardServer.start(preferredPort: config.dashboardPort)
        } catch {
            runtime.recordSystemMessage(
                severity: .critical,
                title: "Dashboard server failed",
                message: error.localizedDescription
            )
        }

        let controller = StatusBarController(
            store: runtime,
            server: dashboardServer,
            tailer: tailer,
            demoFeed: demoFeed,
            discoverer: discoverer,
            configStore: configStore
        )
        dashboardServer.reloadHandler = { [weak controller] in
            controller?.reloadConfigAndRestartWatching()
        }
        statusController = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.stop()
    }
}
