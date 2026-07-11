import Foundation
import TMFormat

/// Portable model of RCP3's NodeLib JSON interchange.
///
/// This module deliberately contains no Truth, RCP, or RealityKit dependencies.
/// Native, agent, and web hosts can therefore share declarations and identities;
/// an Apple-specific adapter owns process-local registration and execution.
public struct NodeLibLibrary: Codable, Equatable, Sendable {
    public var name: String
    public var uniqueID: String
    public var nodes: [Node]
    public var events: [Event]
    public var customTypes: [CustomType]
    public var types: [ObjectType]

    public init(
        name: String = "",
        uniqueID: String,
        nodes: [Node] = [],
        events: [Event] = [],
        customTypes: [CustomType] = [],
        types: [ObjectType] = []
    ) {
        self.name = name
        self.uniqueID = uniqueID
        self.nodes = nodes
        self.events = events
        self.customTypes = customTypes
        self.types = types
    }

    public struct Property: Codable, Equatable, Sendable {
        public var name: String
        public var type: String
        public var module: String?
        public var displayName: String?
        public var isArray: Bool?
        public var isOptional: Bool?

        public init(
            name: String,
            type: String,
            module: String? = nil,
            displayName: String? = nil,
            isArray: Bool? = nil,
            isOptional: Bool? = nil
        ) {
            self.name = name
            self.type = type
            self.module = module
            self.displayName = displayName
            self.isArray = isArray
            self.isOptional = isOptional
        }
    }

    public struct Method: Codable, Equatable, Sendable {
        public var name: String
        public var mangledName: UInt64?
        public var type: String?
        public var parameters: [Property]?
        public var needsObjectArg: Bool?
        public var returnValue: Property?
        public var isAsync: Bool?

        public init(
            name: String,
            mangledName: UInt64? = nil,
            type: String? = nil,
            parameters: [Property]? = nil,
            needsObjectArg: Bool? = nil,
            returnValue: Property? = nil,
            isAsync: Bool? = nil
        ) {
            self.name = name
            self.mangledName = mangledName
            self.type = type
            self.parameters = parameters
            self.needsObjectArg = needsObjectArg
            self.returnValue = returnValue
            self.isAsync = isAsync
        }
    }

    public struct Node: Codable, Equatable, Sendable {
        public var name: String
        public var displayName: String?
        public var category: String?
        public var description: String?
        public var module: String?
        public var object: String?
        public var isPure: Bool?
        public var method: Method?
        public var properties: [Property]?
        public var type: String?

        public init(
            name: String,
            displayName: String? = nil,
            category: String? = nil,
            description: String? = nil,
            module: String? = nil,
            object: String? = nil,
            isPure: Bool? = nil,
            method: Method? = nil,
            properties: [Property]? = nil,
            type: String? = nil
        ) {
            self.name = name
            self.displayName = displayName
            self.category = category
            self.description = description
            self.module = module
            self.object = object
            self.isPure = isPure
            self.method = method
            self.properties = properties
            self.type = type
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public var name: String
        public var displayName: String?
        public var category: String?
        public var description: String?
        public var properties: [Property]?
        public var targeted: Bool?
    }

    public struct CustomType: Codable, Equatable, Sendable {
        public var name: String?
        public var displayName: String
        public var category: String?
        public var description: String?
        public var properties: [Property]?
    }

    public struct ObjectType: Codable, Equatable, Sendable {
        public var module: String
        public var typeName: String
        public var category: String?
    }

    public struct MethodDeclaration: Equatable, Sendable {
        public let identity: String
        public let node: Node
        public let inputs: [Property]
        public let outputs: [Property]
        public let hasExecutionFlow: Bool
    }

    /// Static authoring declarations produced by NodeLib method nodes.
    public var methodDeclarations: [MethodDeclaration] {
        nodes.compactMap { node in
            guard let method = node.method else { return nil }
            return MethodDeclaration(
                identity: TMHash.nodeLibMethodIdentity(
                    nodeName: node.name,
                    libraryUniqueID: uniqueID
                ),
                node: node,
                inputs: method.parameters ?? [],
                outputs: method.returnValue.map { [$0] } ?? [],
                hasExecutionFlow: node.isPure != true
            )
        }
    }
}
