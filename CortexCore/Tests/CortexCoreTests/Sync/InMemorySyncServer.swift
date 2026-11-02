import Foundation
import Synchronization
@testable import CortexCore

/// The sync server (docs/SYNC.md, "Server API") in memory, with the semantics of
/// `sync-server/`: bearer auth, last writer wins by `(modifiedAt, device)`,
/// a `seq` counter that only goes up, epochs (also the rotation when a client's
/// cursor is ahead), blobs, request validation and size limits.
///
/// `handle` takes and gives HTTP-level values, so the protocol fixtures in
/// `sync-server/tests/fixtures` replay against it directly. `SyncAPI` reaches
/// it through `InMemoryServerProtocol`, so the tests also cover the client's
/// JSON. It parses and builds JSON by hand rather than with the client's
/// `Codable` types, so the two implementations stay independent.
final class InMemorySyncServer: Sendable {
    static let token = "test-token-0123456789abcdef"

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data

        var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    }

    struct StoredRecord {
        var collection: String
        var id: String
        var seq: Int
        var modifiedAt: Int
        var device: String
        var deleted: Bool
        var keep: Bool
        var blobs: [String]
        var payload: Data?

        /// The record as a client pulls it.
        var wire: SyncWireRecord {
            SyncWireRecord(
                collection: SyncCollection(rawValue: collection)!, id: id, seq: Int64(seq), modifiedAt: Int64(modifiedAt),
                device: device, deleted: deleted, keep: keep, blobs: blobs, payload: payload)
        }

        func sameWrite(as other: StoredRecord) -> Bool {
            modifiedAt == other.modifiedAt && device == other.device && deleted == other.deleted
                && keep == other.keep && blobs == other.blobs && payload == other.payload
        }
    }

    /// A copy of the server's data, to simulate restoring a backup.
    struct Snapshot {
        fileprivate var state: State
    }

    fileprivate struct State {
        var epoch = UUID().uuidString.replacing("-", with: "").lowercased()
        var nextSeq = 1
        var records: [String: StoredRecord] = [:]   // "collection/id"
        var blobs: [String: Data] = [:]
    }

    let maxJSONBytes: Int
    let maxBlobBytes: Int
    private let state = Mutex(State())
    /// Every request, for tests that count calls.
    private let log = Mutex<[String]>([])

    init(maxJSONBytes: Int = 32 << 20, maxBlobBytes: Int = 32 << 20) {
        self.maxJSONBytes = maxJSONBytes
        self.maxBlobBytes = maxBlobBytes
    }

    // MARK: Test controls

    var epoch: String { state.withLock { $0.epoch } }
    var records: [StoredRecord] { state.withLock { $0.records.values.sorted { $0.seq < $1.seq } } }
    var blobIDs: Set<String> { state.withLock { Set($0.blobs.keys) } }
    var requests: [String] { log.withLock { $0 } }

    func record(_ collection: String, _ id: String) -> StoredRecord? {
        state.withLock { $0.records["\(collection)/\(id)"] }
    }

    func snapshot() -> Snapshot { Snapshot(state: state.withLock { $0 }) }

    /// A restored backup: the old data and the old epoch, `seq` numbers the
    /// clients have already seen handed out again.
    func restore(_ snapshot: Snapshot) { state.withLock { $0 = snapshot.state } }

    /// A server that lost its database: empty, with a new epoch.
    func wipe() { state.withLock { $0 = State() } }

    func removeAllBlobs() { state.withLock { $0.blobs = [:] } }

    /// Blobs that no longer open: as if they were sealed with another key.
    func corruptBlobs() {
        state.withLock { state in state.blobs = state.blobs.mapValues { Data($0.reversed()) } }
    }

    func rotateEpoch() { state.withLock { $0.epoch = Self.newEpoch() } }

    /// Writes a record straight into the database, past validation and
    /// last-writer-wins, the way a compromised server could. It gets a new `seq`.
    func overwrite(_ record: SyncWireRecord) {
        state.withLock { state in
            state.records["\(record.collection)/\(record.id)"] = StoredRecord(
                collection: record.collection, id: record.id, seq: state.nextSeq, modifiedAt: Int(record.modifiedAt),
                device: record.device, deleted: record.deleted, keep: record.keep, blobs: record.blobs,
                payload: record.payload)
            state.nextSeq += 1
        }
    }

    private static func newEpoch() -> String { UUID().uuidString.replacing("-", with: "").lowercased() }

    // MARK: HTTP

    func handle(
        method: String, path: String, query: [String: String] = [:], authorization: String? = nil, body: Data = Data()
    ) -> Response {
        log.withLock { $0.append("\(method) \(path)") }
        var response = route(method: method, path: path, query: query, authorization: authorization, body: body)
        response.headers["X-Sync-Epoch"] = epoch
        return response
    }

    private func route(
        method: String, path: String, query: [String: String], authorization: String?, body: Data
    ) -> Response {
        if method == "GET", path == "/v1/health" {
            return json(["status": "ok", "epoch": epoch, "maxWait": 60])
        }
        guard path.hasPrefix("/v1/") else { return error(404, "not found") }
        guard authorization == "Bearer \(Self.token)" else {
            var response = error(401, "invalid or missing token")
            response.headers["WWW-Authenticate"] = "Bearer"
            return response
        }
        switch (method, path) {
        case ("GET", "/v1/changes"): return changes(query)
        case ("POST", "/v1/push"): return push(body)
        case ("POST", "/v1/blobs/missing"): return missing(body)
        default: break
        }
        if path.hasPrefix("/v1/blobs/") {
            let id = String(path.dropFirst("/v1/blobs/".count))
            guard Self.matches(id, "^[0-9a-f]{32,64}$") else { return error(422, "invalid blob id") }
            switch method {
            case "PUT": return putBlob(id, body)
            case "GET": return getBlob(id)
            default: break
            }
        }
        return error(404, "not found")
    }

    private func changes(_ query: [String: String]) -> Response {
        guard let since = Int(query["since"] ?? "0"), since >= 0,
              let limit = Int(query["limit"] ?? "200"), (1...1000).contains(limit)
        else { return error(422, "invalid query") }
        return state.withLock { state in
            if since > state.nextSeq - 1 {
                // The client has seen a `seq` this database never handed out: it was rolled back.
                state.epoch = Self.newEpoch()
                return json(["records": [], "cursor": 0, "more": false, "epoch": state.epoch])
            }
            let page = state.records.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
            let records = Array(page.prefix(limit))
            return json([
                "records": records.map(Self.jsonObject),
                "cursor": records.last?.seq ?? since,
                "more": page.count > limit,
                "epoch": state.epoch,
            ])
        }
    }

    private func push(_ body: Data) -> Response {
        guard body.count <= maxJSONBytes else { return error(413, "body too large") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let device = object["device"] as? String, Self.matches(device, "^[A-Za-z0-9._-]{1,64}$"),
              let raw = object["records"] as? [[String: Any]], raw.count <= 500
        else { return error(422, "invalid push") }

        var incoming: [StoredRecord] = []
        for item in raw {
            guard let record = Self.parseRecord(item) else { return error(422, "invalid record") }
            incoming.append(record)
        }

        return state.withLock { state in
            var results: [[String: Any]] = []
            for var record in incoming {
                let key = "\(record.collection)/\(record.id)"
                if let stored = state.records[key] {
                    // The server's rule, written out independently of the client's.
                    let storedIsNewer = stored.modifiedAt != record.modifiedAt
                        ? stored.modifiedAt > record.modifiedAt
                        : stored.device > record.device
                    if storedIsNewer {
                        results.append(Self.result(record, "stale", stored.seq))
                        continue
                    }
                    if record.sameWrite(as: stored) {
                        results.append(Self.result(record, "applied", stored.seq))
                        continue
                    }
                }
                // From the counter, never from the highest `seq` present.
                record.seq = state.nextSeq
                state.nextSeq += 1
                state.records[key] = record
                results.append(Self.result(record, "applied", record.seq))
            }
            return json(["results": results, "epoch": state.epoch])
        }
    }

    private func missing(_ body: Data) -> Response {
        guard body.count <= maxJSONBytes else { return error(413, "body too large") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ids = object["ids"] as? [String], ids.count <= 1000,
              ids.allSatisfy({ Self.matches($0, "^[0-9a-f]{32,64}$") })
        else { return error(422, "invalid ids") }
        return state.withLock { state in
            var seen = Set<String>()
            let missing = ids.filter { state.blobs[$0] == nil && seen.insert($0).inserted }
            return json(["missing": missing, "epoch": state.epoch])
        }
    }

    private func putBlob(_ id: String, _ body: Data) -> Response {
        guard body.count <= maxBlobBytes else { return error(413, "body too large") }
        return state.withLock { state in
            let stored = state.blobs[id] == nil
            if stored { state.blobs[id] = body }
            return json(["stored": stored, "epoch": state.epoch])
        }
    }

    private func getBlob(_ id: String) -> Response {
        guard let data = state.withLock({ $0.blobs[id] }) else { return error(404, "no such blob") }
        return Response(status: 200, headers: ["Content-Type": "application/octet-stream"], body: data)
    }

    // MARK: Helpers

    private static func parseRecord(_ item: [String: Any]) -> StoredRecord? {
        guard let collection = item["collection"] as? String,
              ["clip", "snippet", "action", "reading", "knowledge", "device", "meta"].contains(collection),
              let id = item["id"] as? String, matches(id, "^[0-9a-f]{32}$"),
              let modifiedAt = item["modifiedAt"] as? Int, (0...(1 << 53)).contains(modifiedAt),
              modifiedAt <= Int(Date.now.timeIntervalSince1970 * 1000) + 24 * 60 * 60 * 1000,
              let device = item["device"] as? String, matches(device, "^[A-Za-z0-9._-]{1,64}$"),
              let deleted = item["deleted"] as? Bool
        else { return nil }
        let keep = (item["keep"] as? Bool) ?? false
        let blobs = (item["blobs"] as? [String]) ?? []
        guard blobs.count <= 1000, blobs.allSatisfy({ matches($0, "^[0-9a-f]{32,64}$") }) else { return nil }

        var payload: Data?
        switch item["payload"] {
        case let string as String:
            guard let data = Data(base64Encoded: string) else { return nil }
            payload = data
        case is NSNull:
            payload = nil
        default:
            return nil
        }
        // Every record except a tombstone has a payload. A tombstone's is
        // small: sealed since protocol v2, null before.
        guard deleted || payload != nil, (payload?.count ?? 0) <= 1024 || !deleted else { return nil }
        return StoredRecord(
            collection: collection, id: id, seq: 0, modifiedAt: modifiedAt, device: device,
            deleted: deleted, keep: keep, blobs: blobs, payload: payload)
    }

    private static func jsonObject(_ record: StoredRecord) -> [String: Any] {
        [
            "collection": record.collection,
            "id": record.id,
            "seq": record.seq,
            "modifiedAt": record.modifiedAt,
            "device": record.device,
            "deleted": record.deleted,
            "keep": record.keep,
            "blobs": record.blobs,
            "payload": record.payload?.base64EncodedString() ?? NSNull(),
        ]
    }

    private static func result(_ record: StoredRecord, _ status: String, _ seq: Int) -> [String: Any] {
        ["collection": record.collection, "id": record.id, "status": status, "seq": seq]
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }

    private func json(_ object: [String: Any]) -> Response {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return Response(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private func error(_ status: Int, _ detail: String) -> Response {
        let body = try! JSONSerialization.data(withJSONObject: ["detail": detail])
        return Response(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

// MARK: - Reaching it through URLSession

/// Routes `URLSession` requests to hosts registered here to an
/// `InMemorySyncServer`, so `SyncAPI` runs unchanged against the fake.
final class InMemoryServerProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: InMemorySyncServer]>([:])

    /// A `SyncAPI` talking to `server` through a URLSession that never opens a socket.
    static func api(
        for server: InMemorySyncServer, token: String = InMemorySyncServer.token,
        maxJSONBytes: Int = SyncAPI.maxJSONResponseBytes, maxBlobBytes: Int = SyncAPI.maxBlobResponseBytes
    ) -> SyncAPI {
        let host = "sync-\(UUID().uuidString.lowercased()).test"
        servers.withLock { $0[host] = server }
        return SyncAPI(
            baseURL: URL(string: "https://\(host)")!, token: token, session: session,
            maxJSONBytes: maxJSONBytes, maxBlobBytes: maxBlobBytes)
    }

    /// One session for all tests: a session per test Mac is needless churn.
    static let session = SyncAPI.makeSession(protocolClasses: [InMemoryServerProtocol.self])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let response = server.handle(
            method: request.httpMethod ?? "GET", path: url.path, query: query,
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: readBody())

        let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands uploads to a protocol as a stream.
    private func readBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}


/// `SyncTransport` straight onto `InMemorySyncServer.handle`, with the same
/// JSON as `SyncAPI` but without URLSession. The engine tests use this one;
/// `SyncAPITests` cover `SyncAPI` itself.
struct DirectTransport: SyncTransport {
    let server: InMemorySyncServer
    var token = InMemorySyncServer.token

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(), authorized: Bool = true) throws -> InMemorySyncServer.Response {
        let response = server.handle(
            method: method, path: path, query: query, authorization: authorized ? "Bearer \(token)" : nil, body: body)
        switch response.status {
        case 200..<300: return response
        case 401: throw SyncTransportError.unauthorized
        case 413: throw SyncTransportError.payloadTooLarge
        default: throw SyncTransportError.server(status: response.status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: InMemorySyncServer.Response) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.body) } catch { throw SyncTransportError.malformedResponse }
    }

    func health() async throws -> SyncHealth {
        try decode(SyncHealth.self, try send("GET", "/v1/health", authorized: false))
    }

    func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
        try decode(SyncChangesPage.self, try send("GET", "/v1/changes", query: ["since": String(cursor), "limit": String(limit)]))
    }

    func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse {
        struct Body: Encodable { var device: String; var records: [SyncWireRecord] }
        let body = try JSONEncoder().encode(Body(device: device, records: records))
        return try decode(SyncPushResponse.self, try send("POST", "/v1/push", body: body))
    }

    func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs {
        try decode(SyncMissingBlobs.self, try send("POST", "/v1/blobs/missing", body: try JSONEncoder().encode(["ids": ids])))
    }

    func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult {
        try decode(SyncPutBlobResult.self, try send("PUT", "/v1/blobs/\(id)", body: data))
    }

    func blob(id: String) async throws -> SyncBlobDownload? {
        do {
            let response = try send("GET", "/v1/blobs/\(id)")
            return SyncBlobDownload(data: response.body, epoch: response.headers["X-Sync-Epoch"] ?? "")
        } catch SyncTransportError.server(status: 404) {
            return nil
        }
    }
}
