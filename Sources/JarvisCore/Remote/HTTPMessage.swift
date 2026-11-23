import Foundation

/// One HTTP/1.1 request, as much of it as the remote API needs.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public var contentType: String { (headers["content-type"] ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "" }

    /// The token from `Authorization: Bearer …`.
    public var bearerToken: String? {
        guard let h = headers["authorization"] else { return nil }
        let parts = h.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func error(_ status: Int, _ code: String, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        var r = json(status, ["error": code, "message": message])
        for (k, v) in headers { r.headers[k] = v }
        return r
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// The bytes on the wire. Every response closes the connection and forbids caching.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) {
            // A header value never carries a line break, whatever it was built from.
            head += "\(k): \(v.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Reads one request from a byte stream, a piece at a time. Pure: no sockets, so every limit is testable.
public struct HTTPRequestParser {
    public enum Progress: Equatable {
        case needMore
        case complete(HTTPRequest)
        case failed(HTTPResponse)
    }

    public var maxHeaderBytes: Int
    public var maxBodyBytes: Int
    /// Set as soon as the request line and headers have arrived, before any body. Lets the server refuse
    /// a request without a valid token before reading megabytes of audio from it.
    public private(set) var head: HTTPRequest?
    private var buffer = Data()
    private var bodyStart = 0
    private var bodyLength = 0
    private var failure: HTTPResponse?

    public init(maxHeaderBytes: Int = 16 * 1024, maxBodyBytes: Int = 8 * 1024 * 1024) {
        self.maxHeaderBytes = maxHeaderBytes; self.maxBodyBytes = maxBodyBytes
    }

    public mutating func feed(_ data: Data) -> Progress {
        if let failure { return .failed(failure) }
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return buffer.count > maxHeaderBytes ? fail(431, "headers_too_large", "The request headers are too large.") : .needMore
            }
            guard end.lowerBound <= maxHeaderBytes else { return fail(431, "headers_too_large", "The request headers are too large.") }
            guard let text = String(data: buffer.subdata(in: buffer.startIndex..<end.lowerBound), encoding: .utf8) else {
                return fail(400, "bad_request", "The request is not valid HTTP.")
            }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else {
                return fail(400, "bad_request", "The request is not valid HTTP.")
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { return fail(400, "bad_request", "The request is not valid HTTP.") }
                let name = line[..<colon].lowercased()
                guard !name.isEmpty, !name.contains(" ") else { return fail(400, "bad_request", "The request is not valid HTTP.") }
                // The same header twice is ambiguous for the two that decide how a request is read.
                if headers[name] != nil, name == "content-length" || name == "authorization" {
                    return fail(400, "bad_request", "The request repeats a header that may appear only once.")
                }
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if headers["transfer-encoding"] != nil { return fail(501, "chunked_not_supported", "Send the body with a Content-Length.") }
            let target = String(requestLine[1])
            let pathPart = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            var query: [String: String] = [:]
            if pathPart.count == 2 {
                for pair in pathPart[1].split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    query[key] = kv.count == 2 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                }
            }
            let method = String(requestLine[0]).uppercased()
            if let raw = headers["content-length"] {
                guard let n = Int(raw), n >= 0, raw.allSatisfy(\.isNumber) else { return fail(400, "bad_request", "Content-Length is not a number.") }
                guard n <= maxBodyBytes else { return fail(413, "too_large", "The request is larger than \(maxBodyBytes / 1024 / 1024) MB.") }
                bodyLength = n
            } else if method == "POST" || method == "PUT" || method == "PATCH" {
                return fail(411, "length_required", "Send the body with a Content-Length.")
            }
            bodyStart = buffer.distance(from: buffer.startIndex, to: end.upperBound)
            head = HTTPRequest(method: method, path: String(pathPart[0]).removingPercentEncoding ?? String(pathPart[0]), query: query, headers: headers)
        }
        guard var request = head else { return .needMore }
        guard buffer.count >= bodyStart + bodyLength else { return .needMore }
        let from = buffer.index(buffer.startIndex, offsetBy: bodyStart)
        request.body = buffer.subdata(in: from..<buffer.index(from, offsetBy: bodyLength))
        return .complete(request)
    }

    private mutating func fail(_ status: Int, _ code: String, _ message: String) -> Progress {
        let r = HTTPResponse.error(status, code, message)
        failure = r
        return .failed(r)
    }
}
