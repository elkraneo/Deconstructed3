// swift-tools-version: 6.0
import PackageDescription

// The Deconstructed 3 app target is macOS 27+ only (USDKit). These library
// targets are pure-Swift/Foundation parsing code with no OS-specific API, so they
// carry a lower floor to stay buildable and testable on their own; the macOS 27
// constraint is enforced where it matters — the app — when that target lands.
let package = Package(
    name: "Deconstructed3",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3DocumentTests", dependencies: ["RCP3Document"]),
    ]
)
