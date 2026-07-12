import Foundation
import TMFormat

/// Public-JavaScript runtime contracts independently evidenced for Set Component.
///
/// This catalog intentionally does not mirror the editor's much larger component
/// schema. A component appearing in RCP's picker proves its authoring interface, not
/// that its JavaScript constructor or mutation contract is public and usable.
public enum ScriptGraphComponentRuntimeCapabilities {
    public struct PropertyMutation: Sendable, Hashable {
        public let connectorName: String
        public let entityPropertyName: String

        public init(connectorName: String, entityPropertyName: String) {
            self.connectorName = connectorName
            self.entityPropertyName = entityPropertyName
        }
    }

    public enum Strategy: Sendable, Hashable {
        /// Transform is surfaced directly by Entity in RealityKit's JS API.
        case entityProperties([PropertyMutation])
        /// The public JS type has a verified zero-argument constructor.
        case defaultConstructor
    }

    public struct Capability: Sendable, Hashable {
        public let componentName: String
        public let typeHash: UInt64
        public let strategy: Strategy

        public init(componentName: String, strategy: Strategy) {
            self.componentName = componentName
            self.typeHash = TMHash.murmur64a(componentName)
            self.strategy = strategy
        }
    }

    public static let all: [Capability] = [
        .init(componentName: "Transform", strategy: .entityProperties([
            .init(connectorName: "translation", entityPropertyName: "position"),
            .init(connectorName: "rotation", entityPropertyName: "orientation"),
            .init(connectorName: "scale", entityPropertyName: "scale"),
        ])),
        .init(componentName: "AccessibilityComponent", strategy: .defaultConstructor),
        .init(componentName: "BillboardComponent", strategy: .defaultConstructor),
        .init(componentName: "InputTargetComponent", strategy: .defaultConstructor),
    ]

    private static let byHash = Dictionary(uniqueKeysWithValues: all.map { ($0.typeHash, $0) })

    public static func capability(forTypeHash hash: UInt64) -> Capability? {
        byHash[hash]
    }
}
