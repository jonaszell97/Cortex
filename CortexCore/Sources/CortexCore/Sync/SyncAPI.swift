import Foundation

/// The HTTP client of the sync server (docs/SYNC.md, "Server API" and "Scheduling").
public struct SyncAPI: SyncTransport {
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let maxJSONBytes: Int
    private let maxBlobBytes: Int

    /// Health checks give up after this long, so a Mac off the Tailnet notices fast.
    static let healthTimeout: TimeInterval = 5
    /// A waiting `changes` gets this long beyond its wait before it gives up.
    static let waitMargin: TimeInterval = 15
    /// A clock that differs from the server's by more than this is logged.
    static let clockSkewWarning: TimeInterval = 60
    /// The largest JSON answer read. The server ends a page at 8 MB of
    /// payloads; base64 and a large last record stay well below this.
    public static let maxJSONResponseBytes = 64 * 1024 * 1024
    /// The largest blob downloaded: the server's 32 MB limit plus sealing.
    public static let maxBlobResponseBytes = 32 * 1024 * 1024 + 64

    public init(
        baseURL: URL, token: String, session: URLSession = SyncAPI.makeSession(),
        maxJSONBytes: Int = maxJSONResponseBytes, maxBlobBytes: Int = maxBlobResponseBytes
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.maxJSONBytes = maxJSONBytes
        self.maxBlobBytes = maxBlobBytes
    }

    /// Ephemeral, without cache or cookies, and failing fast when the server
    /// can't be reached instead of waiting for connectivity.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration)
    }

    // MARK: - SyncTransport

    public func health() async throws -> SyncHealth {
        let (data, response) = try await send(makeRequest("GET", "v1/health", authorized: false, timeout: Self.healthTimeout))
        checkClock(response)
        return try decode(SyncHealth.self, from: data)
    }

    public func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
        let query = [URLQueryItem(name: "since", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
        let (data, _) = try await send(makeRequest("GET", "v1/changes", query: query))
        return try decode(SyncChangesPage.self, from: data)
    }

    public func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesPage {
        let query = [
            URLQueryItem(name: "since", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "wait", value: String(wait)),
        ]
        let request = makeRequest("GET", "v1/changes", query: query, timeout: TimeInterval(wait) + Self.waitMargin)
        let (data, _) = try await send(request)
        return try decode(SyncChangesPage.self, from: data)
    }

    public func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse {
        struct Body: Encodable {
            var device: String
            var records: [SyncWireRecord]
        }
        var request = makeRequest("POST", "v1/push")
        request.httpBody = try JSONEncoder().encode(Body(device: device, records: records))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request)
        return try decode(SyncPushResponse.self, from: data)
    }

    public func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs {
        var request = makeRequest("POST", "v1/blobs/missing")
        request.httpBody = try JSONEncoder().encode(["ids": ids])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request)
        return try decode(SyncMissingBlobs.self, from: data)
    }

    public func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult {
        var request = makeRequest("PUT", "v1/blobs/\(id)")
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, _) = try await send(request)
        return try decode(SyncPutBlobResult.self, from: body)
    }

    public func blob(id: String) async throws -> SyncBlobDownload? {
        do {
            let (data, response) = try await send(makeRequest("GET", "v1/blobs/\(id)"), limit: maxBlobBytes)
            guard let epoch = response.value(forHTTPHeaderField: "X-Sync-Epoch") else {
                throw SyncTransportError.malformedResponse
            }
            return SyncBlobDownload(data: data, epoch: epoch)
        } catch SyncTransportError.server(status: 404) {
            return nil
        }
    }

    // MARK: - HTTP

    private func makeRequest(
        _ method: String, _ path: String, query: [URLQueryItem] = [], authorized: Bool = true, timeout: TimeInterval? = nil
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if authorized {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    /// Sends a request and reads the answer as it streams in, giving up as
    /// soon as it is larger than `limit`: a declared length is checked
    /// before reading anything.
    private func send(_ request: URLRequest, limit: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        let limit = limit ?? maxJSONBytes
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw SyncTransportError.malformedResponse
            }
            switch http.statusCode {
            case 200..<300: break
            case 401: bytes.task.cancel(); throw SyncTransportError.unauthorized
            case 413: bytes.task.cancel(); throw SyncTransportError.payloadTooLarge
            default: bytes.task.cancel(); throw SyncTransportError.server(status: http.statusCode)
            }
            if http.expectedContentLength > limit {
                bytes.task.cancel()
                throw SyncTransportError.responseTooLarge
            }
            var body: [UInt8] = []
            body.reserveCapacity(Int(max(0, http.expectedContentLength)))
            for try await byte in bytes {
                body.append(byte)
                if body.count > limit {
                    bytes.task.cancel()
                    throw SyncTransportError.responseTooLarge
                }
            }
            return (Data(body), http)
        } catch let error as URLError {
            // A cancelled task is not an unreachable server.
            if error.code == .cancelled { throw CancellationError() }
            throw SyncTransportError.unreachable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SyncTransportError.malformedResponse
        }
    }

    /// Logs a warning when this Mac's clock is far from the server's: last
    /// writer wins uses each Mac's clock (docs/SYNC.md, "What keeps the local app
    /// safe").
    private func checkClock(_ response: HTTPURLResponse) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let header = response.value(forHTTPHeaderField: "Date"),
              let serverDate = formatter.date(from: header)
        else { return }
        let skew = abs(serverDate.timeIntervalSinceNow)
        if skew > Self.clockSkewWarning {
            Log.sync.warning("This Mac's clock differs from the sync server's by \(Int(skew)) s")
        }
    }
}
