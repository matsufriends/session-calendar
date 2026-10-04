import Foundation

// Explicit diagnostic command: never instantiates AppModel or reads history.
enum EmptySyncProbe {
    static func run(allowKeychainPrompt: Bool = false) -> Never {
        DispatchQueue.global().asyncAfter(deadline: .now()+(allowKeychainPrompt ? 120 : 15)) {
            fputs("Empty signed probe timed out; no automatic prompt approval\n",stderr);exit(2)
        }
        Task.detached {
            do {
                fputs(allowKeychainPrompt ? "probe: waiting for user-authorized Keychain access\n" : "probe: reading dedicated key without UI\n",stderr)
                guard let key=(allowKeychainPrompt ? Credential.loadForUserInitiatedProbe() : Credential.load()) else { throw NSError(domain:"ProbeKeyUnavailable",code:1) }
                guard key.publicKey.x963Representation.hex == "0447784cde5c9e07abb63f19e39489a61f1c71dd56a5314c17c9d1b542fea70c6b09d38d1c046a83b4af93ec357a7d816c3d67010e62a4caaec611170f3b7bfb6f" else { throw NSError(domain:"RegisteredPublicKeyMismatch",code:1) }
                fputs("probe: registered key available; sending empty fixture\n",stderr)
                let base="https://session-calendar-sync.matsufriends.com"
                let body=Data("{\"sessions\":[],\"timezone\":\"Asia/Tokyo\"}".utf8)
                var request=URLRequest(url:URL(string:base+"/api/sync")!);request.httpMethod="PUT";request.httpBody=body;request.timeoutInterval=20
                request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                try Credential.sign(&request,body:body,key:key)
                let delegate=NoRedirect()
                let session=URLSession(configuration:.ephemeral,delegate:delegate,delegateQueue:nil)
                let (_,first)=try await session.data(for:request)
                let (_,replay)=try await session.data(for:request)
                var read=URLRequest(url:URL(string:base+"/api/sessions")!);read.allHTTPHeaderFields=request.allHTTPHeaderFields
                let (_,get)=try await session.data(for:read)
                var forged=request;forged.setValue(String(repeating:"0",count:128),forHTTPHeaderField:"X-Sync-Signature")
                let (_,bad)=try await session.data(for:forged)
                let codes=[first,replay,get,bad].map { ($0 as? HTTPURLResponse)?.statusCode ?? 0 }
                let out:[String:Any]=["empty_put":codes[0],"replay_put":codes[1],"writer_get":codes[2],"forged_put":codes[3],"history":false,"private_key_export":false]
                print(String(data:try JSONSerialization.data(withJSONObject:out,options:.sortedKeys),encoding:.utf8)!)
                exit(codes == [200,409,401,401] ? 0 : 1)
            } catch { fputs("Empty signed probe failed: \(error)\n",stderr);exit(1) }
        }
        dispatchMain()
        exit(1)
    }
}
