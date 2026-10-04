import Foundation

@MainActor enum BundleSelfTest {
    static func run() -> Never {
        guard Metadata.normalizedTitle("a\u{1}b") == "a b",
              Updater.parseVersion(Updater.version) != nil,
              let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html"),
              let html = try? Data(contentsOf: htmlURL), !html.isEmpty else {
            fputs("MornSessionCalendar self-test failed\n", stderr)
            exit(1)
        }
        print("{\"ok\":true,\"mode\":\"self-test\",\"resource\":\"index.html\",\"network\":false,\"history\":false}")
        exit(0)
    }
}
