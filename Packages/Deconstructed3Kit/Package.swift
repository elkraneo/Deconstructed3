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
    // `RCP3GraphEditor` (the visual node editor) depends on SwiftFlow, which
    // requires macOS 26+. Deconstructed 3 is macOS 27-only anyway, so we raise the
    // package floor to 26 to satisfy it; the pure-Swift parser/document targets
    // still build fine here.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
        .library(name: "RCP3Runtime", targets: ["RCP3Runtime"]),
        .library(name: "RCP3Viewport", targets: ["RCP3Viewport"]),
        .library(name: "RCP3GraphEditor", targets: ["RCP3GraphEditor"]),
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
        // SwiftFlow — the visual node-graph editor (MIT). Pinned exactly while it is
        // pre-1.0 (0.x API churn). Powers `RCP3GraphEditor`.
        .package(url: "https://github.com/1amageek/swift-flow.git", exact: "0.21.6"),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        // Path-2 script-graph runtime: a public-JavaScriptCore host that runs a
        // compiled graph against an entity model, plus the `tm_graph`→JS compiler.
        // `JavaScriptCore` is a public system framework (auto-links via `import`).
        .target(name: "RCP3Runtime", dependencies: ["RCP3Document", "TMFormat"]),
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
                "RCP3Runtime",
                "RCP3Viewport",
                "RCP3GraphEditor",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        // The visual script-graph node editor: bridges `RCP3ScriptGraph` into a
        // SwiftFlow canvas and renders RCP-styled nodes/wires.
        .target(
            name: "RCP3GraphEditor",
            dependencies: [
                "RCP3Document",
                "TMFormat",
                .product(name: "SwiftFlow", package: "swift-flow"),
            ]
        ),
        .executableTarget(name: "RCP3Dump", dependencies: ["RCP3Document"]),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3DocumentTests", dependencies: ["RCP3Document"]),
        .testTarget(
            name: "RCP3RuntimeTests",
            dependencies: ["RCP3Runtime", "RCP3Document", "TMFormat"]
        ),
        .testTarget(name: "RCP3ViewportTests", dependencies: ["RCP3Viewport"]),
        .testTarget(
            name: "RCP3GraphEditorTests",
            dependencies: ["RCP3GraphEditor", "RCP3Document", "TMFormat"]
        ),
        .testTarget(
            name: "DeconstructedFeatureTests",
            dependencies: [
                "DeconstructedFeature",
                "RCP3Runtime",
                "RCP3Document",
                "TMFormat",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)
