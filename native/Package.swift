// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MornSessionCalendar", platforms: [.macOS(.v14)], products: [.executable(name: "MornSessionCalendar", targets: ["MornSessionCalendar"])], targets: [.executableTarget(name: "MornSessionCalendar"), .testTarget(name: "MornSessionCalendarTests", dependencies: ["MornSessionCalendar"], resources: [.copy("Fixtures")])])
