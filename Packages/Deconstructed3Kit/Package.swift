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
    // Deconstructed 3 is macOS 27-only. The floor is 27 because the canonical
    // runtime target (`RCP3CanonicalRuntime`) depends on `apple/realitykitscripting`
    // (macOS 27), and SPM applies the platform floor per *package*, not per target.
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TMFormat", targets: ["TMFormat"]),
        .library(name: "RCP3NodeLib", targets: ["RCP3NodeLib"]),
        .library(name: "RCP3Document", targets: ["RCP3Document"]),
        .library(name: "RCP3Runtime", targets: ["RCP3Runtime"]),
        .library(name: "RCP3Viewport", targets: ["RCP3Viewport"]),
        .library(name: "RCP3GraphEditor", targets: ["RCP3GraphEditor"]),
        .library(name: "DeconstructedFeature", targets: ["DeconstructedFeature"]),
        .library(name: "RCP3CanonicalRuntime", targets: ["RCP3CanonicalRuntime"]),
        .executable(name: "rcp3-dump", targets: ["RCP3Dump"]),
    ],
    dependencies: [
        // StageView — the proven RealityKit viewport. Pinned to the published git
        // tag (entity-source adoption APIs landed in 0.3.27), so the repo is
        // clone-and-build anywhere with no local sibling required. For active
        // StageView development, swap to `.package(path: "../../../../../StageView")`.
        .package(url: "https://github.com/Reality2713/StageView.git", from: "0.3.28"),
        // TCA is available transitively through StageView; we depend on it
        // DIRECTLY here so `DeconstructedFeature` can own a `@Reducer` feature.
        // Pinned to the same revision StageView resolves (1.26.0).
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
        // Apple's public (MIT) RealityKit Script Graph runtime. Used ONLY by
        // `RCP3CanonicalRuntime` to run a compiled graph on the real runtime.
        .package(url: "https://github.com/apple/realitykitscripting.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "TMFormat"),
        .target(name: "RCP3NodeLib", dependencies: ["TMFormat"]),
        .target(name: "RCP3Document", dependencies: ["TMFormat"]),
        // Path-2 script-graph runtime: a public-JavaScriptCore host that runs a
        // compiled graph against an entity model, plus the `tm_graph`→JS compiler.
        // `JavaScriptCore` is a public system framework (auto-links via `import`).
        .target(name: "RCP3Runtime", dependencies: ["RCP3Document", "TMFormat"]),
        // Canonical runtime bridge (macOS 27): runs a compiled script graph on
        // Apple's real `RealityKitScripting` runtime. Depends on the JS emitter in
        // `RCP3Runtime` (`CanonicalScriptGraphCompiler`) and the public package.
        .target(
            name: "RCP3CanonicalRuntime",
            dependencies: [
                "RCP3Document",
                "RCP3Runtime",
                .product(name: "RealityKitScripting", package: "realitykitscripting"),
            ]
        ),
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
        // The visual script-graph node editor: derives a renderer-agnostic pin model
        // from `RCP3ScriptGraph` (`ScriptGraphPinResolver`) and renders RCP-styled
        // nodes/wires on its own SwiftUI `Canvas`.
        .target(
            name: "RCP3GraphEditor",
            dependencies: [
                "RCP3Document",
                "RCP3NodeLib",
                "TMFormat",
            ]
        ),
        .executableTarget(
            name: "RCP3Dump",
            dependencies: ["RCP3Document", "RCP3GraphEditor", "TMFormat"]
        ),
        .testTarget(name: "TMFormatTests", dependencies: ["TMFormat"]),
        .testTarget(name: "RCP3NodeLibTests", dependencies: ["RCP3NodeLib"]),
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
