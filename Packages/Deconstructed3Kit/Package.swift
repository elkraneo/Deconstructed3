// swift-tools-version: 6.0
import PackageDescription

// Deconstructed3Kit — the logic/library half of Deconstructed 3. The app target
// lives in the sibling Deconstructed3.xcodeproj and depends on this package.
// Pure-Swift/Foundation; the macOS 27 requirement is enforced by the app target.
let package = Package(
    name: "Deconstructed3Kit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
        .executable(name: "rcp3-dump", targets: ["RCP3Dump"]),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        .executableTarget(name: "RCP3Dump", dependencies: ["RCP3Document"]),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3DocumentTests", dependencies: ["RCP3Document"]),
    ]
)
