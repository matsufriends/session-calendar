import Foundation
import Network

final class LocalCalendar {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "SessionCalendar.local")
    private var payload = Data("{\"sessions\":[],\"warnings\":[],\"timezone\":\"Asia/Tokyo\"}".utf8)
    static let port: UInt16 = 18765
    func update(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot), var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["warnings"] = []
        if let output = try? JSONSerialization.data(withJSONObject: json) { queue.async { self.payload = output } }
    }
    func start() throws {
        if listener != nil { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: Self.port)!)
        let server = try NWListener(using: parameters)
        server.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        server.start(queue: queue); listener = server
    }
    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, accumulated: Data())
    }
    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated; bytes.append(data ?? Data())
            if bytes.count > 8192 || error != nil { connection.cancel(); return }
            guard let text = String(data: bytes, encoding: .utf8) else { connection.cancel(); return }
            if !text.contains("\r\n\r\n") {
                if complete { connection.cancel() } else { self.read(connection, accumulated: bytes) }
                return
            }
            let lines = text.components(separatedBy: "\r\n"), words = lines[0].split(separator: " ")
            let host = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
            var status = "404 Not Found", contentType = "text/plain", body = Data("Not Found".utf8)
            if words.count >= 2, words[0] == "GET", ["127.0.0.1:\(Self.port)","localhost:\(Self.port)"].contains(host ?? "") {
                if words[1] == "/api/sessions" || words[1] == "/api/sessions?refresh=1" { status = "200 OK"; contentType = "application/json"; body = self.payload }
                else if words[1] == "/", let file = Bundle.main.url(forResource: "index", withExtension: "html"), let html = try? Data(contentsOf: file) { status = "200 OK"; contentType = "text/html; charset=utf-8"; body = html }
            } else { status = "403 Forbidden"; body = Data("Forbidden".utf8) }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8); response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
