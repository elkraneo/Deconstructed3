import Foundation

/// Render-neutral declarations supplied by an external authoring engine.
/// Identifiers and type tokens are opaque to the graph editor.
public struct ScriptGraphExternalAuthoringCatalog: Codable, Hashable, Sendable {
    public var nodes: [Node]
    public init(nodes: [Node]) { self.nodes = nodes }

    public struct Node: Codable, Hashable, Sendable, Identifiable {
        public enum Category: String, Codable, Hashable, Sendable {
            case events, controlFlow, logic, entity, math, make, string
            case variables, components, utility
        }
        public enum Execution: String, Codable, Hashable, Sendable { case pure, action }

        public var id: String
        public var operationID: String
        public var displayName: String
        public var category: Category
        public var execution: Execution
        public var isAsync: Bool
        public var inputs: [Pin]
        public var outputs: [Pin]

        public init(
            id: String, operationID: String, displayName: String, category: Category,
            execution: Execution, isAsync: Bool = false,
            inputs: [Pin] = [], outputs: [Pin] = []
        ) {
            self.id = id
            self.operationID = operationID
            self.displayName = displayName
            self.category = category
            self.execution = execution
            self.isAsync = isAsync
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    public struct Pin: Codable, Hashable, Sendable {
        public var name: String
        public var displayName: String
        public var typeToken: String
        public var isOptional: Bool
        public var isVariadic: Bool

        public init(
            name: String, displayName: String, typeToken: String,
            isOptional: Bool = false, isVariadic: Bool = false
        ) {
            self.name = name
            self.displayName = displayName
            self.typeToken = typeToken
            self.isOptional = isOptional
            self.isVariadic = isVariadic
        }
    }
}

/// Minimal injection seam for private or third-party authoring engines.
public protocol ScriptGraphExternalAuthoringCatalogProviding: Sendable {
    func externalAuthoringCatalog() async throws -> ScriptGraphExternalAuthoringCatalog
}
