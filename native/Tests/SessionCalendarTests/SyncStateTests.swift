import XCTest
import CryptoKit
@testable import SessionCalendar
@MainActor final class SyncStateTests: XCTestCase {
    func fixture(_ code: Int = 200, failures: Int = 0) -> (AppModel, UserDefaults, String) {
        let name = "review.fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        var nonces=Set<String>()
        let model = AppModel(defaults: defaults, startBackgroundTasks: false,
          collectMetadata: { Collection(snapshot: Snapshot(sessions: [SessionRecord(id: "fixture", tool: "Codex", start: "2026-10-03T01:00:00Z", last_activity: nil, project: "/tmp/Private", title: "private title")]), failures: failures) },
          keyProvider: { P256.Signing.PrivateKey() },
          keyAuthorizer: { P256.Signing.PrivateKey() },
          transport: { req in
            if req.httpMethod != "PUT" || req.value(forHTTPHeaderField:"X-Sync-Signature")==String(repeating:"0",count:128) { return (Data(),HTTPURLResponse(url:req.url!,statusCode:401,httpVersion:nil,headerFields:nil)!) }
            let nonce=req.value(forHTTPHeaderField:"X-Sync-Nonce")!
            if !nonces.insert(nonce).inserted { return (Data(),HTTPURLResponse(url:req.url!,statusCode:409,httpVersion:nil,headerFields:nil)!) }
            let payload = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let rows = payload["sessions"] as! [[String: Any]]
            if !rows.isEmpty { XCTAssertEqual(rows[0]["title"] as? String, "Codex セッション fixture")
            XCTAssertEqual(rows[0]["project"] as? String, "Private") }
            return (Data("{\"ok\":true,\"count\":\(rows.count)}".utf8), HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
          })
        return (model, defaults, name)
    }
    func testUnsetEndpointAndAnonymousDefault() async {
        let (m,d,n)=fixture(); defer { d.removePersistentDomain(forName:n) }
        XCTAssertFalse(m.enabled); XCTAssertFalse(m.includeTitles)
        m.enable(); XCTAssertFalse(m.enabled); XCTAssertTrue(m.showSettings); XCTAssertNotNil(m.errorMessage)
        m.syncNow(); await m.waitForSyncForTesting(); XCTAssertNil(m.lastSync)
    }
    func testSuccessAndPauseAndAnonymousPayload() async {
        let (m,d,n)=fixture(); defer { d.removePersistentDomain(forName:n) }
        m.endpoint="https://fixture.invalid/api/sync"; m.enable(); await m.waitForSyncForTesting()
        XCTAssertEqual(m.lastCount,1); XCTAssertNotNil(m.lastSync); XCTAssertFalse(m.busy)
        m.pause(); XCTAssertFalse(m.enabled); XCTAssertFalse(d.bool(forKey:"syncEnabled"))
        XCTAssertEqual(m.status,"送信は一時停止中")
    }
    func testQuitClearsActiveSessionButPreservesLoginSyncPreference() async {
        let (m,d,n)=fixture();defer { d.removePersistentDomain(forName:n) }
        m.endpoint="https://fixture.invalid/api/sync";m.enable();await m.waitForSyncForTesting()
        XCTAssertTrue(d.bool(forKey:"syncEnabled"))
        m.shutdown()
        XCTAssertFalse(m.enabled)
        XCTAssertTrue(d.bool(forKey:"syncEnabled"))
        m.syncNow();await m.waitForSyncForTesting()
        XCTAssertFalse(m.enabled)
    }
    func testFailureDoesNotMarkSuccess() async {
        let (m,d,n)=fixture(500); defer { d.removePersistentDomain(forName:n) }
        m.endpoint="https://fixture.invalid/api/sync"; m.enable(); await m.waitForSyncForTesting()
        XCTAssertNil(m.lastSync); XCTAssertEqual(m.lastCount,0); XCTAssertNotNil(m.errorMessage); XCTAssertFalse(m.busy)
    }
    func testReadFailureStopsTransmission() async {
        let (m,d,n)=fixture(failures:1); defer { d.removePersistentDomain(forName:n) }
        m.endpoint="https://fixture.invalid/api/sync"; m.enable(); await m.waitForSyncForTesting()
        XCTAssertNil(m.lastSync); XCTAssertEqual(m.status,"読取失敗")
    }
    func testRapidRequestsStartOnlyOneTransmission() async throws {
        let name = "review.fixture." + UUID().uuidString
        let d = UserDefaults(suiteName:name)!; defer { d.removePersistentDomain(forName:name) }
        var requests = 0, authorizations=0
        var nonces=Set<String>()
        let m = AppModel(defaults:d,startBackgroundTasks:false,
            collectMetadata:{ Collection(snapshot:Snapshot(sessions:[]),failures:0) },
            keyProvider:{ XCTFail("Background key reread");return nil },
            keyAuthorizer:{ authorizations += 1;return P256.Signing.PrivateKey() },
            transport:{ req in
                if req.httpMethod != "PUT" || req.value(forHTTPHeaderField:"X-Sync-Signature")==String(repeating:"0",count:128) { return (Data(),HTTPURLResponse(url:req.url!,statusCode:401,httpVersion:nil,headerFields:nil)!) }
                let nonce=req.value(forHTTPHeaderField:"X-Sync-Nonce")!
                if !nonces.insert(nonce).inserted { return (Data(),HTTPURLResponse(url:req.url!,statusCode:409,httpVersion:nil,headerFields:nil)!) }
                requests += 1
                return (Data("{\"ok\":true,\"count\":0}".utf8),HTTPURLResponse(url:req.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
        m.endpoint="https://fixture.invalid/api/sync";m.enable();m.syncNow()
        await m.waitForSyncForTesting()
        XCTAssertEqual(requests,2);XCTAssertEqual(authorizations,1)
        m.syncNow();await m.waitForSyncForTesting()
        XCTAssertEqual(requests,2);XCTAssertEqual(authorizations,1)
    }
    func testPauseBeforeScheduledTaskPreventsSending() async {
        let (m,d,n)=fixture();defer { d.removePersistentDomain(forName:n) }
        m.endpoint="https://fixture.invalid/api/sync";m.enable();m.pause()
        await m.waitForSyncForTesting()
        XCTAssertNil(m.lastSync);XCTAssertFalse(m.enabled);XCTAssertFalse(m.busy)
    }
}
