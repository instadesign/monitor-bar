// swift-tools-version: 6.0
// Monitor Bar: control the UPERFECT 4K OLED portable monitor's own settings from the Mac.
//
//   MonitorCore  the DDC/CI protocol code (talks to the monitor). Shared by both programs below.
//   monitorctl   the command-line tool.
//   MonitorBar   the menu-bar app.
//
// Build everything with ./build.sh (needs only the Command Line Tools, not Xcode).
import PackageDescription

let package = Package(
    name: "monitor-bar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "monitorctl", targets: ["monitorctl"]),
        .executable(name: "MonitorBar", targets: ["MonitorBar"]),
    ],
    targets: [
        .target(name: "MonitorCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "monitorctl", dependencies: ["MonitorCore"]),
        .executableTarget(name: "MonitorBar", dependencies: ["MonitorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
