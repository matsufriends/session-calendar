import Foundation
import CryptoKit

enum SyncHandshake {
    static func verify(url: URL, key: P256.Signing.PrivateKey, transport: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        let body=Data("{\"check\":true}".utf8)
        var request=URLRequest(url:url.appendingPathComponent("check"));request.httpMethod="PUT";request.httpBody=body;request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        try Credential.sign(&request,body:body,key:key)
        let (data,first)=try await transport(request)
        guard (first as? HTTPURLResponse)?.statusCode==200,
              let ack=try JSONSerialization.jsonObject(with:data) as? [String:Any],ack["ok"] as? Bool==true,ack["check"] as? Bool==true else { throw NSError(domain:"SyncHandshake",code:1) }
    }
}
