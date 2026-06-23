import Foundation
import Network

public final class DashboardServer {
    private let store: RuntimeStore
    private let configStore: AppConfigStore
    private let queue = DispatchQueue(label: "RoonLogWatcher.DashboardServer")
    private var listener: NWListener?
    public var reloadHandler: (() -> Void)?
    public private(set) var url: URL?

    public init(store: RuntimeStore, configStore: AppConfigStore) {
        self.store = store
        self.configStore = configStore
    }

    public func start(preferredPort: UInt16) throws {
        var lastError: Error?
        for port in preferredPort..<(preferredPort + 20) {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { continue }
            do {
                let listener = try NWListener(using: .tcp, on: endpointPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
                let resolvedURL = URL(string: "http://127.0.0.1:\(port)")!
                self.url = resolvedURL
                store.setDashboardURL(resolvedURL)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? DashboardServerError.noAvailablePort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard isComplete || error != nil || self.isCompleteHTTPRequest(nextBuffer) else {
                self.receiveRequest(on: connection, buffer: nextBuffer)
                return
            }

            let request = String(data: nextBuffer, encoding: .utf8) ?? ""
            let response = self.route(request: request)
            self.send(response, on: connection)
        }
    }

    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return false
        }
        let headerData = data[..<headerRange.lowerBound]
        let header = String(data: headerData, encoding: .utf8) ?? ""
        let contentLength = header
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }
                return Int(parts[1])
            }
            .first ?? 0
        return data.count - headerRange.upperBound >= contentLength
    }

    private func route(request: String) -> HTTPResponse {
        let parsed = HTTPRequest(raw: request)
        let path = parsed.path
        switch path {
        case "/", "/index.html":
            return .html(DashboardAssets.html)
        case "/style.css":
            return .text(DashboardAssets.css, contentType: "text/css; charset=utf-8")
        case "/app.js":
            return .text(DashboardAssets.javascript, contentType: "application/javascript; charset=utf-8")
        case "/api/snapshot", "/data":
            return .json(snapshotJSON())
        case "/api/config":
            if parsed.method == "POST" {
                return saveConfigJSON(parsed.body)
            }
            return .json(configStore.jsonDocument())
        case "/api/config/reload":
            configStore.reload()
            return .json(configStore.jsonDocument())
        case "/api/watch/reload":
            DispatchQueue.main.async { [weak self] in
                self?.reloadHandler?()
            }
            return .json(#"{"ok":true}"#)
        case "/api/export/logs.txt":
            return .attachment(logExportText(), fileName: "roon-live-logs.txt", contentType: "text/plain; charset=utf-8")
        case "/health":
            let summary = store.statusSummary()
            return .text("ok\nmode=\(summary.mode.rawValue)\nhealth=\(summary.health.state.rawValue)\nscore=\(summary.healthScore)\n", contentType: "text/plain; charset=utf-8")
        default:
            return HTTPResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: "Not found")
        }
    }

    private func snapshotJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(store.snapshot())) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func saveConfigJSON(_ body: String) -> HTTPResponse {
        do {
            try configStore.saveJSON(body)
            return .json(configStore.jsonDocument())
        } catch {
            return .json(
                #"{"ok":false,"message":"\#(jsonEscape(error.localizedDescription))"}"#,
                status: "400 Bad Request"
            )
        }
    }

    private func logExportText() -> String {
        store.logExportText()
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let body = Data(response.body.utf8)
        var headers = [
            "HTTP/1.1 \(response.status)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Access-Control-Allow-Origin: *",
            "Connection: close"
        ]
        for (key, value) in response.extraHeaders {
            headers.append("\(key): \(value)")
        }
        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        var payload = Data()
        payload.append(headerData)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var body: String

    init(raw: String) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
        let tokens = firstLine.split(separator: " ")
        method = tokens.first.map(String.init) ?? "GET"
        if tokens.count >= 2 {
            let rawPath = String(tokens[1])
            path = rawPath.components(separatedBy: "?").first ?? rawPath
        } else {
            path = "/"
        }
    }
}

private func jsonEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
}

public enum DashboardServerError: Error {
    case noAvailablePort
}

private struct HTTPResponse {
    var status: String
    var contentType: String
    var body: String
    var extraHeaders: [String: String] = [:]

    static func html(_ body: String) -> HTTPResponse {
        HTTPResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: body)
    }

    static func json(_ body: String, status: String = "200 OK") -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    static func text(_ body: String, contentType: String) -> HTTPResponse {
        HTTPResponse(status: "200 OK", contentType: contentType, body: body)
    }

    static func attachment(_ body: String, fileName: String, contentType: String) -> HTTPResponse {
        HTTPResponse(
            status: "200 OK",
            contentType: contentType,
            body: body,
            extraHeaders: ["Content-Disposition": "attachment; filename=\"\(fileName)\""]
        )
    }
}
