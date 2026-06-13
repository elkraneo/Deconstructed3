// swift-tools-version: 6.0
import PackageDescription

// The Deconstructed 3 app is macOS 27+ at runtime (USDKit). The library and tool
// targets are pure-Swift/Foundation + SwiftUI/AppKit with no OS-specific API beyond
// a low floor, so they carry a conservative platform to stay buildable and testable
// on their own; the macOS 27 requirement is enforced at the app/runtime layer.
let package = Package(
    name: "Deconstructed3",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
        .executable(name: "Deconstructed3App", targets: ["Deconstructed3App"]),
        .executable(name: "rcp3-dump", targets: ["RCP3Dump"]),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        .executableTarget(name: "Deconstructed3App", dependencies: ["RCP3Document"]),
        .executableTarget(name: "RCP3Dump", dependencies: ["RCP3Document"]),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3DocumentTests", dependencies: ["RCP3Document"]),
    ]
)
