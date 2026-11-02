import Foundation
import Testing
@testable import CortexCore

/// Replays the protocol fixtures of `sync-server/tests/fixtures` (the same
/// files pytest replays against the real server) against `InMemorySyncServer`,
/// which keeps the fake honest.
@Suite struct SyncFixtureTests {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "sync-server/tests/fixtures", directoryHint: .isDirectory)

    static let scenarios: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    @Test func fixturesExist() {
        #expect(Self.scenarios.count >= 4)
    }

    @Test(arguments: SyncFixtureTests.scenarios)
    func replay(_ name: String) throws {
        let data = try Data(contentsOf: Self.directory.appending(path: "\(name).json"))
        let scenario = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try #require(scenario["steps"] as? [[String: Any]])
        let server = InMemorySyncServer()
        var bound: [String: String] = [:]

        for (index, step) in steps.enumerated() {
            let request = try #require(step["request"] as? [String: Any])
            let expected = try #require(step["response"] as? [String: Any])
            let where_ = "\(name) step \(index)"

            let rawPath = try #require(request["path"] as? String)
            let components = try #require(URLComponents(string: "http://x" + rawPath))
            let query = Dictionary(
                (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            var body = Data()
            if let json = request["json"] {
                body = try JSONSerialization.data(withJSONObject: json)
            } else if let base64 = request["bodyBase64"] as? String {
                body = try #require(Data(base64Encoded: base64))
            }
            let authorized = (request["auth"] as? Bool) ?? true
            let response = server.handle(
                method: request["method"] as! String, path: components.path, query: query,
                authorization: authorized ? "Bearer \(InMemorySyncServer.token)" : nil, body: body)

            #expect(response.status == (expected["status"] as? Int), "\(where_)")
            if let expectedJSON = expected["json"] {
                let actual = try #require(response.json, "\(where_)")
                let resolved = Self.resolve(expectedJSON, actual, &bound)
                #expect((resolved as AnyObject).isEqual(actual), "\(where_): \(String(decoding: response.body, as: UTF8.self))")
            }
            if let base64 = expected["bodyBase64"] as? String {
                #expect(response.body == Data(base64Encoded: base64), "\(where_)")
            }
            let epoch = try #require(response.headers["X-Sync-Epoch"])
            #expect(epoch == bound["epoch", default: epoch], "\(where_)")
            bound["epoch"] = epoch
        }
    }

    /// `expected` with its placeholders replaced by the matching parts of `actual`.
    static func resolve(_ expected: Any, _ actual: Any?, _ bound: inout [String: String]) -> Any {
        if let string = expected as? String {
            if string == "<epoch>" {
                if bound["epoch"] == nil { bound["epoch"] = actual as? String }
                return bound["epoch"] as Any
            }
            if string == "<any>" { return actual as Any }
        }
        if let expected = expected as? [String: Any], let actual = actual as? [String: Any] {
            return expected.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = resolve(pair.value, actual[pair.key], &bound)
            }
        }
        if let expected = expected as? [Any], let actual = actual as? [Any], expected.count == actual.count {
            return zip(expected, actual).map { resolve($0, $1, &bound) }
        }
        return expected
    }
}

/// `SyncAPI` against the fake server, through URLSession.
@Suite struct SyncAPITests {
    let server = InMemorySyncServer(maxJSONBytes: 4096, maxBlobBytes: 1024)
    var api: SyncAPI { InMemoryServerProtocol.api(for: server) }

    func record(_ n: Int, modifiedAt: Int64 = 1_792_483_200_000, deleted: Bool = false) -> SyncWireRecord {
        SyncWireRecord(
            collection: .clip, id: String(format: "%032x", n), modifiedAt: modifiedAt, device: "mac-a",
            deleted: deleted, payload: deleted ? nil : Data("sealed".utf8))
    }

    @Test func healthNeedsNoToken() async throws {
        let api = InMemoryServerProtocol.api(for: server, token: "")
        let health = try await api.health()
        #expect(health.status == "ok")
        #expect(health.epoch == server.epoch)
    }

    @Test func wrongTokenIsUnauthorized() async throws {
        let api = InMemoryServerProtocol.api(for: server, token: "wrong")
        await #expect(throws: SyncTransportError.unauthorized) { try await api.changes(since: 0, limit: 10) }
        await #expect(throws: SyncTransportError.unauthorized) { try await api.push(device: "mac-a", records: []) }
    }

    @Test func pushAndPullRoundTrip() async throws {
        let api = api
        let pushed = try await api.push(device: "mac-a", records: [record(1), record(2, deleted: true)])
        #expect(pushed.results.map(\.status) == [.applied, .applied])
        #expect(pushed.results.map(\.seq) == [1, 2])
        #expect(pushed.epoch == server.epoch)

        let page = try await api.changes(since: 0, limit: 10)
        #expect(page.records.map(\.seq) == [1, 2])
        #expect(page.records[0].payload == Data("sealed".utf8))
        #expect(page.records[1].deleted && page.records[1].payload == nil)
        #expect(page.cursor == 2 && !page.more)
    }

    @Test func pagingAndStaleAnswers() async throws {
        let api = api
        _ = try await api.push(device: "mac-a", records: [record(1), record(2), record(3)])
        let first = try await api.changes(since: 0, limit: 2)
        #expect(first.records.count == 2 && first.more && first.cursor == 2)

        let stale = try await api.push(device: "mac-a", records: [record(1, modifiedAt: 1)])
        #expect(stale.results.map(\.status) == [.stale])
        #expect(stale.results[0].seq == 1)
    }

    @Test func blobsRoundTrip() async throws {
        let api = api
        let id = String(repeating: "ab", count: 16)
        #expect(try await api.missingBlobs([id]).missing == [id])
        #expect(try await api.putBlob(id: id, data: Data("bytes".utf8)).stored)
        #expect(try await api.putBlob(id: id, data: Data("other".utf8)).stored == false)
        #expect(try await api.missingBlobs([id]).missing.isEmpty)

        let download = try #require(try await api.blob(id: id))
        #expect(download.data == Data("bytes".utf8))
        #expect(download.epoch == server.epoch)
        #expect(try await api.blob(id: String(repeating: "cd", count: 16)) == nil)
    }

    @Test func oversizedBodiesAreTooLarge() async throws {
        let api = api
        let big = SyncWireRecord(
            collection: .clip, id: String(format: "%032x", 1), modifiedAt: 1, device: "mac-a", deleted: false,
            payload: Data(repeating: 7, count: 8000))
        await #expect(throws: SyncTransportError.payloadTooLarge) { try await api.push(device: "mac-a", records: [big]) }
        await #expect(throws: SyncTransportError.payloadTooLarge) {
            try await api.putBlob(id: String(repeating: "ab", count: 16), data: Data(count: 2000))
        }
    }

    @Test func answersOverTheLimitAreNotRead() async throws {
        let api = InMemoryServerProtocol.api(for: InMemorySyncServer(), maxJSONBytes: 2000, maxBlobBytes: 100)
        let records = (1...3).map { n in
            SyncWireRecord(
                collection: .clip, id: String(format: "%032x", n), modifiedAt: 1, device: "mac-a", deleted: false,
                payload: Data(repeating: 7, count: 1000))
        }
        _ = try await api.push(device: "mac-a", records: records)
        await #expect(throws: SyncTransportError.responseTooLarge) { try await api.changes(since: 0, limit: 10) }
        #expect(try await api.changes(since: 0, limit: 1).records.count == 1)

        let id = String(repeating: "ab", count: 16)
        _ = try await api.putBlob(id: id, data: Data(count: 200))
        await #expect(throws: SyncTransportError.responseTooLarge) { try await api.blob(id: id) }
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedUpFront() async throws {
        final class Huge: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Length": "1000000000", "X-Sync-Epoch": "e"])!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(count: 10))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let api = SyncAPI(baseURL: URL(string: "https://x.test")!, token: "t",
                          session: SyncAPI.makeSession(protocolClasses: [Huge.self]), maxBlobBytes: 1000)
        await #expect(throws: SyncTransportError.responseTooLarge) { try await api.blob(id: String(repeating: "ab", count: 16)) }
    }

    @Test func aServerThatIsNotThereIsUnreachable() async throws {
        let api = SyncAPI(baseURL: URL(string: "https://nowhere.test")!, token: "t",
                          session: SyncAPI.makeSession(protocolClasses: [InMemoryServerProtocol.self]))
        await #expect(throws: SyncTransportError.unreachable) { try await api.health() }
    }

    @Test func aWrongAnswerIsMalformed() async throws {
        // The route exists, but the body isn't what the protocol says.
        final class Garbage: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("<html>captive portal</html>".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let api = SyncAPI(baseURL: URL(string: "https://x.test")!, token: "t",
                          session: SyncAPI.makeSession(protocolClasses: [Garbage.self]))
        await #expect(throws: SyncTransportError.malformedResponse) { try await api.health() }
    }

    @Test func serverErrorsKeepTheirStatus() async throws {
        let api = api
        await #expect(throws: SyncTransportError.server(status: 422)) { try await api.changes(since: 0, limit: 5000) }
    }
}

/// Runs against a real `sync-server` when `SYNC_TEST_SERVER_URL` and
/// `SYNC_TEST_SERVER_TOKEN` are set, for example:
///
///     cd sync-server && SYNC_TOKEN=test-token-0123456789 DATA_DIR=/tmp/s uv run uvicorn app.main:app --port 8787
///     SYNC_TEST_SERVER_URL=http://127.0.0.1:8787 SYNC_TEST_SERVER_TOKEN=test-token-0123456789 make test
@Suite struct RealServerTests {
    static let url = ProcessInfo.processInfo.environment["SYNC_TEST_SERVER_URL"]
    static let token = ProcessInfo.processInfo.environment["SYNC_TEST_SERVER_TOKEN"]

    @Test(.enabled(if: RealServerTests.url != nil && RealServerTests.token != nil))
    func twoMacsConvergeThroughTheRealServer() async throws {
        let url = try #require(URL(string: Self.url ?? ""))
        let key = SyncKey.generate()
        let a = try makePeer(url: url, key: key)
        let b = try makePeer(url: url, key: key)

        // The server may hold data from earlier runs under other keys, so this
        // test uses its own key and checks only what it wrote. An old key
        // check would fail the pull, hence a fresh database for the server.
        _ = try a.snippets.save(Snippet(name: "From A", body: "hello"))
        try await a.engine.publishKeyCheck()
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.snippetBodies() == ["From A": "hello"])

        try b.snippets.delete(id: try #require(try await b.snippets.all().first?.id))
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try a.snippetBodies().isEmpty)
    }

    private func makePeer(url: URL, key: SyncKey) throws -> SyncPeer {
        SyncPeer(
            database: try makeTestDatabase(), transport: HookedTransport(SyncAPI(baseURL: url, token: Self.token ?? "")),
            key: key)
    }
}
