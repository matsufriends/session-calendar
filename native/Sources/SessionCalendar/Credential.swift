import Foundation
import Security
import CryptoKit

enum Credential {
    private static let service = "com.matsufriends.SessionCalendar"
    private static let account = "signing-key-v1"
    static func load() -> P256.Signing.PrivateKey? { read(allowInteraction: false) }
    // Only the explicit, manually launched empty-fixture command calls this.
    // SecItemCopyMatching asks macOS for access; no ACL is edited by the app.
    static func loadForUserInitiatedProbe() -> P256.Signing.PrivateKey? { read(allowInteraction: true) }
    private static func read(allowInteraction: Bool) -> P256.Signing.PrivateKey? {
        // Legacy login-keychain items ignore kSecUseAuthenticationUIFail on macOS.
        // Disable optional interaction for this process as well; never alter ACLs.
        guard SecKeychainSetUserInteractionAllowed(allowInteraction)==errSecSuccess else { return nil }
        defer { if allowInteraction { SecKeychainSetUserInteractionAllowed(false) } }
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationUI as String:allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&result)
        guard status==errSecSuccess,let data=result as? Data else {
            if status != errSecItemNotFound { fputs("Dedicated Keychain read failed: OSStatus \(status); interaction=\(allowInteraction)\n",stderr) }
            return nil
        }
        return try? P256.Signing.PrivateKey(rawRepresentation:data)
    }
    static func provision() throws -> String {
        let interaction=SecKeychainSetUserInteractionAllowed(false)
        guard interaction==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(interaction)) }
        if let key=load() { return key.publicKey.x963Representation.hex }
        let key=P256.Signing.PrivateKey()
        let item: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecValueData as String:key.rawRepresentation,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        let status=SecItemAdd(item as CFDictionary,nil)
        guard status==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        return key.publicKey.x963Representation.hex
    }
    static func sign(_ request: inout URLRequest, body: Data, key: P256.Signing.PrivateKey) throws {
        guard let url=request.url,let host=url.host else { throw CocoaError(.fileReadInvalidFileName) }
        let origin="https://"+host+(url.port.map { ":\($0)" } ?? "")
        let stamp=String(Int(Date().timeIntervalSince1970))
        var nonce=Data(count:32)
        let status=nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }
        guard status==errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        guard let method=request.httpMethod,method=="PUT" else { throw CocoaError(.fileReadInvalidFileName) }
        let path=url.path
        let canonical=["SESSION-CALENDAR-V1",method,origin,path,stamp,nonce.hex,Data(SHA256.hash(data:body)).hex].joined(separator:"\n")
        let signature=try key.signature(for:Data(canonical.utf8)).rawRepresentation
        request.setValue(stamp,forHTTPHeaderField:"X-Sync-Timestamp")
        request.setValue(nonce.hex,forHTTPHeaderField:"X-Sync-Nonce")
        request.setValue(signature.hex,forHTTPHeaderField:"X-Sync-Signature")
    }
}
extension Data { var hex: String { map { String(format:"%02x",$0) }.joined() } }
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
