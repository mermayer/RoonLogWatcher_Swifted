import Foundation

public final class DemoLogFeed {
    private let onLine: (String, String) -> Void
    private let queue = DispatchQueue(label: "RoonLogWatcher.DemoLogFeed")
    private var timer: DispatchSourceTimer?
    private var index = 0
    private let file = "/Demo/RoonServer/Logs/RoonServer_log.txt"

    public init(onLine: @escaping (String, String) -> Void) {
        self.onLine = onLine
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(1400))
            source.setEventHandler { [weak self] in
                self?.emit()
            }
            timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func emit() {
        let line = sampleLines[index % sampleLines.count]
        index += 1
        onLine(file, line)
    }

    private var sampleLines: [String] {
        [
            "06/22 17:03:11 Info: [stats] 845 MB Physical 384 MB Managed 461 MB estimated Unmanaged 1280 MB Virtual",
            "06/22 17:03:13 Trace: [zone Living Room] [Enhanced, 44.1kHz 16bit => 44.1kHz 24bit] [10% buf] [PLAYING @ 0:01] The Nightfly - Donald Fagen",
            "06/22 17:03:18 Info: [raat/tcpaudiosource] connected to Living Room endpoint",
            "06/22 17:03:24 Warn: state changed: Prepared => Buffering for zone Living Room",
            "06/22 17:03:25 Warn: [raat/tcpaudiosource] disconnecting: transport lost for zone Living Room",
            "06/22 17:03:31 Info: [stats] 928 MB Physical 406 MB Managed 522 MB estimated Unmanaged 1322 MB Virtual",
            "06/22 17:03:35 Info: onplayfeedback Playing zone Living Room",
            "06/22 17:03:44 Error: network timeout while refreshing streaming metadata"
        ]
    }
}
