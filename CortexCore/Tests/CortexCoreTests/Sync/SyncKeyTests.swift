import Foundation
import Testing
@testable import CortexCore

@Suite struct SyncKeyTests {
    /// 0x00, 0x01, … 0x1f: the key the reference IDs below were computed with
    /// (HKDF-SHA256 and HMAC-SHA256 in Python's standard library).
    let fixed = try! SyncKey(rawValue: Data(0..<32))

    func isHex32(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }

    // MARK: Key

    @Test func generatesRandomKeys() {
        let first = SyncKey.generate()
        #expect(first.rawValue.count == 32)
        #expect(first != SyncKey.generate())
    }

    @Test func rejectsWrongLength() {
        #expect(throws: SyncKeyError.malformedKey(byteCount: 16)) {
            try SyncKey(rawValue: Data(count: 16))
        }
    }

    @Test func keychainRoundTrip() throws {
        let secrets = DatabaseKeyTests.MemoryStore()
        #expect(try SyncKey.load(from: secrets) == nil)
        let key = SyncKey.generate()
        try key.save(to: secrets)
        #expect(try SyncKey.load(from: secrets) == key)
        #expect(try secrets.data(for: "sync-key") == key.rawValue)
    }

    // MARK: IDs

    @Test func recordIDsMatchTheReference() {
        #expect(fixed.recordID(.clip, localKey: "hello") == "20a85a2fabed6a7e7e6f9590b541804e")
        #expect(fixed.keyCheckID == "94f97a7bf616a3f251e30886210d5b3b")
    }

    @Test func blobIDsMatchTheReference() {
        #expect(fixed.blobID(for: Data("image bytes".utf8)) == "3d751113de8c81fc42110da1a476d2bb")
    }

    @Test func recordIDsAreStableAndSeparate() throws {
        let copy = try SyncKey(rawValue: fixed.rawValue)
        let id = fixed.recordID(.snippet, localKey: "abc")
        #expect(isHex32(id))
        #expect(copy.recordID(.snippet, localKey: "abc") == id)
        #expect(fixed.recordID(.clip, localKey: "abc") != id)
        #expect(fixed.recordID(.snippet, localKey: "abd") != id)
        #expect(SyncKey.generate().recordID(.snippet, localKey: "abc") != id)
        // The separator keeps "clip" + "\0a" from meeting "clipa".
        #expect(fixed.recordID(.clip, localKey: "a") != fixed.recordID(.clip, localKey: "\0a"))
    }

    @Test func blobIDsDependOnContentAndKey() {
        let data = Data("png".utf8)
        let id = fixed.blobID(for: data)
        #expect(isHex32(id))
        #expect(fixed.blobID(for: data) == id)
        #expect(fixed.blobID(for: Data("jpg".utf8)) != id)
        #expect(SyncKey.generate().blobID(for: data) != id)
    }

    // MARK: Sealing

    func header(
        _ collection: SyncCollection = .clip, _ localKey: String = "hash", modifiedAt: Int64 = 1_792_483_200_000,
        device: String = "mac-a", deleted: Bool = false
    ) -> SyncRecordHeader {
        SyncRecordHeader(
            collection: collection, id: fixed.recordID(collection, localKey: localKey), modifiedAt: modifiedAt,
            device: device, deleted: deleted)
    }

    @Test func sealAndOpen() throws {
        let plaintext = Data(#"{"v":1,"plainText":"hunter2"}"#.utf8)
        let sealed = try fixed.seal(plaintext, for: header())
        #expect(try fixed.open(sealed, for: header()) == plaintext)
        #expect(sealed.range(of: Data("hunter2".utf8)) == nil)
        // A fresh nonce every time.
        #expect(try fixed.seal(plaintext, for: header()) != sealed)
    }

    @Test func theAADNamesEveryFieldTheServerKeeps() {
        let id = fixed.recordID(.snippet, localKey: "s")
        let aad = header(.snippet, "s", modifiedAt: 42, device: "MAC-B", deleted: true).aad
        #expect(String(decoding: aad, as: UTF8.self) == "v2/snippet/\(id)/42/MAC-B/true")
    }

    @Test func sealedPayloadIsBoundToItsRecordAndMetadata() throws {
        let sealed = try fixed.seal(Data("payload".utf8), for: header())
        var changed: [SyncRecordHeader] = []
        for change in [
            { (h: inout SyncRecordHeader) in h.id = self.fixed.recordID(.clip, localKey: "other") },
            { $0.collection = .snippet },
            // Restamped to win last-writer-wins: a rollback to an old payload.
            { $0.modifiedAt += 1 },
            { $0.device = "mac-x" },
            // Turned into a tombstone.
            { $0.deleted = true },
        ] {
            var h = header()
            change(&h)
            changed.append(h)
        }
        for h in changed {
            #expect(throws: SyncKeyError.cannotOpen) { try fixed.open(sealed, for: h) }
        }
        #expect(throws: SyncKeyError.cannotOpen) { try fixed.openBlob(sealed, id: header().id) }
        // Nor does it open as a v1 payload.
        #expect(throws: SyncKeyError.cannotOpen) { try fixed.openV1(sealed, collection: .clip, id: header().id) }
    }

    @Test func openFailsWithAnotherKeyOrChangedBytes() throws {
        let h = header(.snippet, "s")
        let sealed = try fixed.seal(Data("payload".utf8), for: h)
        #expect(throws: SyncKeyError.cannotOpen) { try SyncKey.generate().open(sealed, for: h) }
        var tampered = sealed
        tampered[tampered.startIndex + 14] ^= 0x01
        #expect(throws: SyncKeyError.cannotOpen) { try fixed.open(tampered, for: h) }
        #expect(throws: SyncKeyError.cannotOpen) { try fixed.open(Data("short".utf8), for: h) }
    }

    @Test func tombstones() throws {
        #expect(SyncKey.isTombstone(SyncKey.tombstoneContents))
        #expect(!SyncKey.isTombstone(Data(#"{"v":1,"deleted":false}"#.utf8)))
        #expect(!SyncKey.isTombstone(Data(#"{"v":1}"#.utf8)))
        #expect(!SyncKey.isTombstone(Data("junk".utf8)))
    }

    @Test func sealAndOpenBlobs() throws {
        let data = Data(repeating: 0xAB, count: 300_000)
        let id = fixed.blobID(for: data)
        let sealed = try fixed.sealBlob(data, id: id)
        #expect(try fixed.openBlob(sealed, id: id) == data)
        #expect(throws: SyncKeyError.cannotOpen) { try fixed.openBlob(sealed, id: fixed.blobID(for: Data())) }
    }

    func keyCheckRecord(_ payload: Data?, id: String? = nil, modifiedAt: Int64 = 7, device: String = "mac-a") -> SyncWireRecord {
        SyncWireRecord(
            collection: .meta, id: id ?? fixed.keyCheckID, modifiedAt: modifiedAt, device: device, deleted: false,
            payload: payload)
    }

    @Test func keyCheck() throws {
        let record = keyCheckRecord(try fixed.sealedKeyCheck(modifiedAt: 7, device: "mac-a"))
        #expect(try SyncKey(rawValue: fixed.rawValue).opensKeyCheck(record))
        #expect(!SyncKey.generate().opensKeyCheck(record))
        #expect(!fixed.opensKeyCheck(keyCheckRecord(Data("junk".utf8))))
        #expect(!fixed.opensKeyCheck(keyCheckRecord(nil)))
        // Bound to its metadata and its ID like any record.
        #expect(!fixed.opensKeyCheck(keyCheckRecord(record.payload, modifiedAt: 8)))
        #expect(!fixed.opensKeyCheck(keyCheckRecord(record.payload, id: fixed.recordID(.meta, localKey: "other"))))
        // Another payload sealed for the same record isn't a key check.
        let other = try fixed.seal(Data("x".utf8), for: SyncRecordHeader(
            collection: .meta, id: fixed.keyCheckID, modifiedAt: 7, device: "mac-a", deleted: false))
        #expect(!fixed.opensKeyCheck(keyCheckRecord(other)))
    }

    @Test func aKeyCheckSealedByProtocolV1StillOpens() throws {
        // Its contents are fixed, so whatever its metadata says, it proves the key.
        let v1 = try SyncKeyTestV1.seal(SyncKey.keyCheckContents, key: fixed, collection: .meta, id: fixed.keyCheckID)
        #expect(fixed.opensKeyCheck(keyCheckRecord(v1, modifiedAt: 123, device: "anything")))
        #expect(!SyncKey.generate().opensKeyCheck(keyCheckRecord(v1)))
    }

    // MARK: Pairing code

    @Test func pairingCodeRoundTrip() throws {
        let pairing = SyncPairing(
            serverURL: URL(string: "https://cortex-sync.example.dev")!,
            token: "0123456789abcdef0123456789abcdef",
            key: SyncKey.generate())
        let code = pairing.code
        #expect(code.hasPrefix("cxsync1:"))
        #expect(!code.dropFirst(8).contains { "+/=".contains($0) })
        #expect(try SyncPairing(code: code) == pairing)
        #expect(try SyncPairing(code: "  \(code)\n") == pairing)
    }

    @Test func pairingCodeKeepsURLPathAndPort() throws {
        let pairing = SyncPairing(
            serverURL: URL(string: "http://mac-mini.tailnet-name.ts.net:8787/sync")!,
            token: "t/o+k=e n", key: fixed)
        #expect(try SyncPairing(code: pairing.code) == pairing)
    }

    @Test(arguments: [
        "",
        "cxsync2:abc",
        "cxsync1:",
        "cxsync1:!!!not base64!!!",
        "cxsync1:" + Self.base64url(#"{"u":"https://x.dev","t":"tok"}"#),
        "cxsync1:" + Self.base64url(#"{"u":"https://x.dev","t":"tok","k":"AAAA"}"#),
        "cxsync1:" + Self.base64url(#"{"u":"ftp://x.dev","t":"tok","k":"\#(Self.key64)"}"#),
        "cxsync1:" + Self.base64url(#"{"u":"not a url","t":"tok","k":"\#(Self.key64)"}"#),
        "cxsync1:" + Self.base64url(#"{"u":"https://x.dev","t":"","k":"\#(Self.key64)"}"#),
    ])
    func rejectsMalformedPairingCodes(code: String) {
        #expect(throws: SyncKeyError.malformedPairingCode) { try SyncPairing(code: code) }
    }

    @Test func acceptsHandWrittenPairingCode() throws {
        let code = "cxsync1:" + Self.base64url(#"{"u":"https://x.dev","t":"tok","k":"\#(Self.key64)"}"#)
        let pairing = try SyncPairing(code: code)
        #expect(pairing.serverURL.absoluteString == "https://x.dev")
        #expect(pairing.key.rawValue == Data(0..<32))
    }

    static let key64 = Data(0..<32).base64EncodedString()

    static func base64url(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
