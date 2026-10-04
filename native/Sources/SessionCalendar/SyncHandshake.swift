import Foundation
import CryptoKit

enum SyncHandshake {
    static func verify(url: URL, key: P256.Signing.PrivateKey, transport: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        let body=Data("{\"sessions\":[],\"timezone\":\"Asia/Tokyo\"}".utf8)
        var request=URLRequest(url:url);request.httpMethod="PUT";request.httpBody=body;request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        try Credential.sign(&request,body:body,key:key)
        let (data,first)=try await transport(request)
        guard (first as? HTTPURLResponse)?.statusCode==200,
              let ack=try JSONSerialization.jsonObject(with:data) as? [String:Any],ack["ok"] as? Bool==true,ack["count"] as? Int==0 else { throw NSError(domain:"SyncHandshake",code:1) }
        let (_,replay)=try await transport(request)
        var read=URLRequest(url:url.deletingLastPathComponent().appendingPathComponent("sessions"));read.allHTTPHeaderFields=request.allHTTPHeaderFields
        let (_,viewer)=try await transport(read)
        var forged=request;forged.setValue(String(repeating:"0",count:128),forHTTPHeaderField:"X-Sync-Signature")
        let (_,bad)=try await transport(forged)
        guard [replay,viewer,bad].map({($0 as? HTTPURLResponse)?.statusCode}) == [409,401,401] else { throw NSError(domain:"SyncHandshake",code:2) }
    }
}
