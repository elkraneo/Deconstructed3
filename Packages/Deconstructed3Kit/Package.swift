// swift-tools-version: 6.0
import PackageDescription

// Deconstructed3Kit — the logic/library half of Deconstructed 3. The app target
// lives in the sibling Deconstructed3.xcodeproj and depends on this package.
// Pure-Swift/Foundation; the macOS 27 requirement is enforced by the app target.
//
// `RCP3Viewport` adopts the StageView package's proven `RealityKitStageView`
// viewport (RealityKit + ArcballCamera + selection outline + grid/IBL). We feed
// it `.tm_*`-reconstructed RealityKit entities via `RealityKitProvider.setModel`,
// reusing StageView's RealityKit render path — not its USD-import path.
//
// StageView is consumed from its public git URL (`Reality2713/StageView`),
// pinned by tag — OSS/CI-clonable. For active StageView development, swap to a
// local path. See `Docs/StageView-Adoption.md` for the trade-off.
let package = Package(
    name: "Deconstructed3Kit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
        .library(name: "RCP3Viewport", targets: ["RCP3Viewport"]),
        .library(name: "DeconstructedFeature", targets: ["DeconstructedFeature"]),
        .executable(name: "rcp3-dump", targets: ["RCP3Dump"]),
    ],
    dependencies: [
        // StageView — public git URL, pinned by tag. (Local path for StageView dev:
        //   .package(path: "../../../../../StageView"))
        .package(url: "https://github.com/Reality2713/StageView.git", from: "0.3.26"),
        // TCA is available transitively through StageView; we depend on it
        // DIRECTLY here so `DeconstructedFeature` can own a `@Reducer` feature.
        // Pinned to the same revision StageView resolves (1.26.0).
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        .target(
            name: "RCP3Viewport",
            dependencies: [
                "RCP3Document",
                .product(name: "RealityKitStageView", package: "StageView"),
            ]
        ),
        // The TCA feature layer: `DocumentFeature` (open → edit → save) and the
        // SwiftUI views that drive it. Depends on the document model, the
        // viewport, and TCA directly.
        .target(
            name: "DeconstructedFeature",
            dependencies: [
                "RCP3Document",
                "RCP3Viewport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .executableTarget(name: "RCP3Dump", dependencies: ["RCP3Document"]),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3DocumentTests", dependencies: ["RCP3Document"]),
        .testTarget(name: "RCP3ViewportTests", dependencies: ["RCP3Viewport"]),
        .testTarget(
            name: "DeconstructedFeatureTests",
            dependencies: [
                "DeconstructedFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)
