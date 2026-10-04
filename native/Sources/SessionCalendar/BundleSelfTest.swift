import Foundation

@MainActor enum BundleSelfTest {
    static func run() -> Never {
        do {
            let input = SessionRecord(id: "bundle-fixture", tool: "Codex", start: "2026-10-03T01:00:00Z", last_activity: nil, project: "/tmp/FixtureProject", title: "fixture private title")
            let prepared = Metadata.prepared(Snapshot(sessions: [input]), includeTitles: false)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any]
            guard let rows = json?["sessions"] as? [[String: Any]], rows.count == 1,
                  rows[0]["project"] as? String == "FixtureProject",
                  rows[0]["title"] as? String == "Codex セッション bundle-f",
                  rows[0]["end"] is NSNull,
                  AppModel.syncURL("https://fixture.invalid/api/sync") != nil,
                  AppModel.syncURL("http://fixture.invalid/api/sync") == nil,
                  Updater.parseVersion(Updater.version) != nil,
                  let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html"),
                  !(try Data(contentsOf: htmlURL)).isEmpty else {
                throw NSError(domain: "SessionCalendarSelfTest", code: 1)
            }
            print("{\"ok\":true,\"mode\":\"self-test\",\"resource\":\"index.html\",\"anonymous_payload\":true,\"network\":false,\"credentials\":false,\"history\":false}")
            exit(0)
        } catch {
            fputs("SessionCalendar self-test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
