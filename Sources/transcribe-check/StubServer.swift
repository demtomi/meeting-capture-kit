// A loopback-only HTTP stub standing in for the speech-to-text API.
//
// URLProtocol stubbing cannot reach the transcriber, because the transcriber runs as a
// CHILD process and a URLProtocol only intercepts the process that registered it. So the
// check runs a real socket on 127.0.0.1 and points the child at it through the loopback
// base-URL override. The child then does exactly what it does against the real API, and
// every upload that reaches this server is counted.
import Foundation
import Network

struct StubRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let bodyBytes: Int
    /// The multipart file name ("mic.wav", "system.wav"), nil for a non-upload.
    let fileName: String?
    /// The multipart text fields (model_id, diarize, ...).
    let fields: [String: String]

    var track: String? { fileName.map { ($0 as NSString).deletingPathExtension } }
}

struct StubResponse {
    var status: Int
    var body: String
    /// Seconds to wait before answering, to hold an upload in flight.
    var delay: Double = 0
}

final class StubServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-server", attributes: .concurrent)
    private let lock = NSLock()
    private var _requests: [StubRequest] = []
    /// Scripted answers per track name, consumed in order. "*" applies to any upload.
    private var script: [String: [StubResponse]] = [:]
    /// What an upload gets once its script is exhausted.
    var defaultResponse: (StubRequest) -> StubResponse
    var userResponse = StubResponse(status: 200, body: #"{"subscription":{"tier":"test"}}"#)
    private(set) var port: UInt16 = 0
    /// When set, a new connection is accepted and read ONCE, then never read again and never
    /// answered, so the client's send blocks on a full socket buffer.
    var stallUploads = false
    private var stalled: [NWConnection] = []

    init(defaultResponse: @escaping (StubRequest) -> StubResponse) throws {
        self.defaultResponse = defaultResponse
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        port = p
    }

    func stop() { listener.cancel() }

    func reset() {
        lock.lock(); _requests = []; script = [:]; stalled.forEach { $0.cancel() }; stalled = []; lock.unlock()
        stallUploads = false
    }

    func enqueue(_ track: String, _ responses: [StubResponse]) {
        lock.lock(); script[track, default: []].append(contentsOf: responses); lock.unlock()
    }

    var requests: [StubRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var uploads: [StubRequest] { requests.filter { $0.fileName != nil } }
    func uploads(track: String) -> Int { uploads.filter { $0.track == track }.count }

    // ------------------------------------------------------------------ plumbing
    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        if stallUploads {
            lock.lock(); stalled.append(conn); lock.unlock()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in }
            return
        }
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf) {
                self.answer(conn, req)
                return
            }
            if done || error != nil { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    /// A complete request, or nil while more bytes are needed.
    private func parse(_ buf: Data) -> StubRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headEnd = buf.range(of: sep) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buf[headEnd.upperBound...])
        if let cl = headers["content-length"].flatMap(Int.init) {
            guard body.count >= cl else { return nil }
            body = body.prefix(cl)
        } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
            guard let decoded = dechunk(body) else { return nil }
            body = decoded
        }
        let (file, fields) = multipart(body, contentType: headers["content-type"] ?? "")
        return StubRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, bodyBytes: body.count, fileName: file, fields: fields)
    }

    private func dechunk(_ d: Data) -> Data? {
        var out = Data(); var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let r = d.range(of: crlf, in: i..<d.endIndex) else { return nil }
            let sizeHex = String(decoding: d[i..<r.lowerBound], as: UTF8.self)
            guard let n = Int(sizeHex.split(separator: ";")[0], radix: 16) else { return nil }
            if n == 0 { return out }
            let start = r.upperBound
            guard d.distance(from: start, to: d.endIndex) >= n + 2 else { return nil }
            let end = d.index(start, offsetBy: n)
            out.append(d[start..<end])
            i = d.index(end, offsetBy: 2)
        }
    }

    private func multipart(_ body: Data, contentType: String) -> (String?, [String: String]) {
        guard let b = contentType.components(separatedBy: "boundary=").last, contentType.contains("multipart") else {
            return (nil, [:])
        }
        let boundary = Data(("--" + b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))).utf8)
        var file: String?
        var fields: [String: String] = [:]
        var parts: [Data] = []
        var cursor = body.startIndex
        while let r = body.range(of: boundary, in: cursor..<body.endIndex) {
            if cursor != body.startIndex { parts.append(body[cursor..<r.lowerBound]) }
            cursor = r.upperBound
        }
        for part in parts {
            guard let hEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let h = String(decoding: part[part.startIndex..<hEnd.lowerBound], as: UTF8.self)
            guard let nameRange = h.range(of: "name=\"") else { continue }
            let name = String(h[nameRange.upperBound...].prefix { $0 != "\"" })
            if let fr = h.range(of: "filename=\"") {
                file = String(h[fr.upperBound...].prefix { $0 != "\"" })
            } else {
                // Trimmed as BYTES. Swift reads "\r\n" as one Character, so a
                // String-level removeLast(2) eats the last letter of the value.
                var v = Data(part[hEnd.upperBound...])
                if v.suffix(2) == Data("\r\n".utf8) { v.removeLast(2) }
                fields[name] = String(decoding: v, as: UTF8.self)
            }
        }
        return (file, fields)
    }

    private func answer(_ conn: NWConnection, _ req: StubRequest) {
        lock.lock()
        _requests.append(req)
        var resp: StubResponse
        if req.fileName == nil {
            resp = userResponse
        } else if let t = req.track, var q = script[t], !q.isEmpty {
            resp = q.removeFirst(); script[t] = q
        } else if var q = script["*"], !q.isEmpty {
            resp = q.removeFirst(); script["*"] = q
        } else {
            resp = defaultResponse(req)
        }
        lock.unlock()
        let send = {
            let body = Data(resp.body.utf8)
            var head = "HTTP/1.1 \(resp.status) STUB\r\n"
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
        if resp.delay > 0 { queue.asyncAfter(deadline: .now() + resp.delay, execute: send) } else { send() }
    }
}
