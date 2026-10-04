import XCTest
import CryptoKit
@testable import SessionCalendar
final class SignatureTests: XCTestCase {
    func testCanonicalRawSignatureBindsOriginTimestampNonceAndBody() throws {
        let key=P256.Signing.PrivateKey(), body=Data("{\"sessions\":[],\"timezone\":\"Asia/Tokyo\"}".utf8)
        var req=URLRequest(url:URL(string:"https://fixture.invalid/api/sync")!);req.httpMethod="PUT"
        try Credential.sign(&req,body:body,key:key)
        XCTAssertNil(req.value(forHTTPHeaderField:"Authorization"))
        let stamp=try XCTUnwrap(req.value(forHTTPHeaderField:"X-Sync-Timestamp"))
        let nonce=try XCTUnwrap(req.value(forHTTPHeaderField:"X-Sync-Nonce"))
        let signature=try XCTUnwrap(req.value(forHTTPHeaderField:"X-Sync-Signature"))
        XCTAssertEqual(nonce.count,64);XCTAssertEqual(signature.count,128)
        XCTAssertLessThan(abs(Double(stamp)!-Date().timeIntervalSince1970),2)
        let bytes=Data(stride(from:0,to:signature.count,by:2).map { i in UInt8(signature.dropFirst(i).prefix(2),radix:16)! })
        let signed=try P256.Signing.ECDSASignature(rawRepresentation:bytes)
        let canonical=["SESSION-CALENDAR-V1","PUT","https://fixture.invalid","/api/sync",stamp,nonce,Data(SHA256.hash(data:body)).hex].joined(separator:"\n")
        XCTAssertTrue(key.publicKey.isValidSignature(signed,for:Data(canonical.utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(signed,for:Data((canonical+"tampered").utf8)))
        XCTAssertFalse(P256.Signing.PrivateKey().publicKey.isValidSignature(signed,for:Data(canonical.utf8)))
    }
}
