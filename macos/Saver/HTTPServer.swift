import Foundation
import Network
import UniformTypeIdentifiers

/// A tiny static file HTTP server built on Network.framework.
///
/// It exists because the web viewer needs:
///   - a real http:// origin (workers, WASM, CacheStorage do not work from file://)
///   - cross-origin isolation headers (COOP/COEP) for SharedArrayBuffer
///   - HTTP Range support, the RS cache loader resumes partial downloads
///
/// Everything is served from `127.0.0.1` on an ephemeral port. Connections are
/// closed after each response (`Connection: close`), which keeps the parser tiny
/// and is plenty for a screensaver.
final class HTTPServer {
    private let webRoot: URL
    private let cacheRoot: URL?
    private let logFile: URL?
    private let listener: NWListener
    private let acceptQueue = DispatchQueue(label: "osrs.saver.http.listener", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "osrs.saver.http.connection",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let logLock = NSLock()

    private(set) var port: UInt16 = 0

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "ttf": "font/ttf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "wasm": "application/wasm",
        "map": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "glsl": "text/plain; charset=utf-8",
    ]

    init?(webRoot: URL, cacheRoot: URL?, logFile: URL?) {
        self.webRoot = webRoot
        self.cacheRoot = cacheRoot
        self.logFile = logFile

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        guard let listener = try? NWListener(using: parameters) else {
            return nil
        }
        self.listener = listener
    }

    // MARK: - Lifecycle

    /// Starts listening and returns the port once it is ready.
    func start(timeout: TimeInterval = 3) -> UInt16? {
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                self?.log("listener failed: \(error)")
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: acceptQueue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        return port == 0 ? nil : port
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Logging

    func log(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }

        let line = "[\(Self.formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        NSLog("OSRSMapSaver: %@", message)
        guard let logFile, let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: connectionQueue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let chunk {
                buffer.append(chunk)
            }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerEnd.lowerBound]
                self.respond(to: headerData, on: connection)
                return
            }

            if isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: buffer)
        }
    }

    private struct Request {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
    }

    private func parse(_ headerData: Data) -> Request? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let target = String(parts[1])
        var path = target
        var query = ""
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            query = String(target[target.index(after: questionMark)...])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return Request(
            method: String(parts[0]).uppercased(),
            path: path,
            query: query,
            headers: headers
        )
    }

    // MARK: - Routing

    private func respond(to headerData: Data, on connection: NWConnection) {
        guard let request = parse(headerData) else {
            sendStatus(connection, status: 400, reason: "Bad Request")
            return
        }

        if request.path == "/__diag" {
            let decoded = request.query.removingPercentEncoding ?? request.query
            log("diag \(decoded)")
            sendStatus(connection, status: 204, reason: "No Content")
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            sendStatus(connection, status: 405, reason: "Method Not Allowed")
            return
        }

        var fileURL: URL?
        if request.path.hasPrefix("/caches/"), let cacheRoot {
            let relative = String(request.path.dropFirst("/caches/".count))
            fileURL = resolve(root: cacheRoot, relativePath: relative)
        } else {
            let relative = request.path == "/" ? "index.html" : String(request.path.dropFirst())
            fileURL = resolve(root: webRoot, relativePath: relative)

            // Single page app fallback for unknown non-asset routes.
            if fileURL == nil || !FileManager.default.fileExists(atPath: fileURL!.path) {
                if !relative.contains(".") {
                    fileURL = webRoot.appendingPathComponent("index.html")
                }
            }
        }

        guard let fileURL else {
            log("\(request.method) \(request.path) 404")
            sendStatus(connection, status: 404, reason: "Not Found")
            return
        }

        serve(
            fileURL,
            request: request,
            connection: connection,
            cacheable: request.path.hasPrefix("/static/")
        )
    }

    private func resolve(root: URL, relativePath: String) -> URL? {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        var url = root.appendingPathComponent(decoded)
        url.standardize()
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }

    // MARK: - File serving

    private func contentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = Self.mimeTypes[ext] {
            return type
        }
        if let type = UTType(filenameExtension: ext)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }

    private func serve(
        _ url: URL,
        request: Request,
        connection: NWConnection,
        cacheable: Bool
    ) {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = FileHandle(forReadingAtPath: path)
        else {
            sendStatus(connection, status: 404, reason: "Not Found")
            return
        }
        // NB: the handle must stay open for the streaming path below; ARC closes
        // it once `stream` releases its reference.

        var start: UInt64 = 0
        var end: UInt64 = size > 0 ? size - 1 : 0
        var status = 200
        var headers: [String: String] = [:]

        if let rangeHeader = request.headers["range"], let parsed = parseRange(rangeHeader, size: size) {
            switch parsed {
            case .satisfiable(let rangeStart, let rangeEnd):
                start = rangeStart
                end = rangeEnd
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            case .unsatisfiable:
                var extra = baseHeaders()
                extra["Content-Range"] = "bytes */\(size)"
                sendHeaders(connection, status: 416, reason: "Range Not Satisfiable", headers: extra, length: 0)
                return
            }
        }

        let length = size == 0 ? 0 : end - start + 1
        headers["Content-Type"] = contentType(for: url)
        headers["Accept-Ranges"] = "bytes"
        headers["Cache-Control"] = cacheable
            ? "public, max-age=31536000, immutable"
            : "no-cache, must-revalidate"
        if let modified = attributes[.modificationDate] as? Date {
            headers["Last-Modified"] = Self.httpDateFormatter.string(from: modified)
        }

        log("\(request.method) \(url.lastPathComponent) \(status) \(length)")
        let headerData = mergeHeaders(status: status, headers: headers, length: length)

        guard request.method == "GET", length > 0 else {
            send(connection, data: headerData)
            return
        }

        try? handle.seek(toOffset: start)

        if length <= smallFileThreshold {
            guard let body = try? handle.read(upToCount: Int(length)) else {
                send(connection, data: headerData)
                return
            }
            send(connection, data: headerData + body)
            return
        }

        sendFile(
            connection,
            header: headerData,
            fileHandle: handle,
            remaining: length
        )
    }

    private enum RangeResult {
        case satisfiable(UInt64, UInt64)
        case unsatisfiable
    }

    private func parseRange(_ value: String, size: UInt64) -> RangeResult? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)

        // Only handle the single-range form, which is all browsers ask for here.
        let components = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }

        let startText = components[0].trimmingCharacters(in: .whitespaces)
        let endText = components[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            // bytes=-500 => last 500 bytes
            guard let suffix = UInt64(endText), suffix > 0 else { return nil }
            let start = suffix >= size ? 0 : size - suffix
            return .satisfiable(start, size - 1)
        }

        guard let start = UInt64(startText) else { return nil }
        guard start < size else { return .unsatisfiable }
        let end = endText.isEmpty ? size - 1 : min(UInt64(endText) ?? (size - 1), size - 1)
        guard end >= start else { return .unsatisfiable }
        return .satisfiable(start, end)
    }

    // MARK: - Responses

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private func baseHeaders() -> [String: String] {
        [
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Resource-Policy": "same-origin",
            "Server": "OSRSMapSaver",
            "Connection": "close",
        ]
    }

    private func mergeHeaders(status: Int, headers: [String: String], length: UInt64) -> Data {
        var all = baseHeaders()
        for (key, value) in headers {
            all[key] = value
        }
        all["Content-Length"] = String(length)

        return serializedHeaders(status: status, headers: all)
    }

    private func serializedHeaders(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        default: return "Error"
        }
    }

    private func sendStatus(_ connection: NWConnection, status: Int, reason: String) {
        var headers = baseHeaders()
        headers["Content-Length"] = "0"
        let data = serializedHeaders(status: status, headers: headers)
        send(connection, data: data)
    }

    private func sendHeaders(
        _ connection: NWConnection,
        status: Int,
        reason: String,
        headers: [String: String],
        length: UInt64
    ) {
        var all = baseHeaders()
        for (key, value) in headers {
            all[key] = value
        }
        all["Content-Length"] = String(length)
        send(connection, data: serializedHeaders(status: status, headers: all))
    }

    private func send(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Sends the header, then streams the file body in chunks. Unlike `send`,
    /// the connection stays open until the last chunk has been written.
    private func sendFile(
        _ connection: NWConnection,
        header: Data,
        fileHandle: FileHandle,
        remaining: UInt64
    ) {
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            self.stream(connection, fileHandle: fileHandle, remaining: remaining)
        })
    }

    private let chunkSize = 4 * 1024 * 1024
    private let smallFileThreshold: UInt64 = 8 * 1024 * 1024

    private func stream(
        _ connection: NWConnection,
        fileHandle: FileHandle,
        remaining: UInt64
    ) {
        guard remaining > 0 else {
            connection.cancel()
            return
        }

        let want = Int(min(UInt64(chunkSize), remaining))
        guard let chunk = try? fileHandle.read(upToCount: want), !chunk.isEmpty else {
            connection.cancel()
            return
        }

        connection.send(
            content: chunk,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                self.stream(
                    connection,
                    fileHandle: fileHandle,
                    remaining: remaining - UInt64(chunk.count)
                )
            }
        )
    }
}
