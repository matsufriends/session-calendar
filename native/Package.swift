// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SessionCalendar", platforms: [.macOS(.v14)], products: [.executable(name: "SessionCalendar", targets: ["SessionCalendar"])], targets: [.executableTarget(name: "SessionCalendar"), .testTarget(name: "SessionCalendarTests", dependencies: ["SessionCalendar"], resources: [.process("Fixtures")])])
