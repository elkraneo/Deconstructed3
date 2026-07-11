import Foundation
import JavaScriptCore
import RCP3Document

/// Observable calls made by canonical Script Graph JavaScript while running in the
/// deterministic preview host.
///
/// This is deliberately an API-surface adapter, not a RealityKit simulation. It
/// implements the entity/component/material calls emitted by
/// ``CanonicalScriptGraphCompiler`` and records their effects. Physics, rendering,
/// collision detection, and material shading remain the responsibility of the real
/// RealityKitScripting runtime.
@MainActor
public final class CanonicalRuntimeObservation {
    public enum Operation: Equatable, Sendable {
        case event(String)
        case getComponent(String)
        case setComponent(String)
        case addChild(preservingWorldTransform: Bool)
        case getMaterial(slot: Int)
        case setMaterial(slot: Int)
        case getMaterialParameter(String)
        case setMaterialParameter(String)
    }

    public fileprivate(set) var operations: [Operation] = []

    public init() {}
}

/// Executes canonical RealityKit Script Graph JavaScript against a small,
/// deterministic mock of the *public* runtime API.
///
/// The host is useful for compiler integration tests and non-rendering previews. It
/// proves that handlers, data flow, component calls, hierarchy actions, and material
/// access execute without claiming to reproduce RealityKit's renderer or physics.
@MainActor
public final class CanonicalScriptRuntimeHost {
    public let state: RuntimeEntityState
    public let observation: CanonicalRuntimeObservation
    public let scriptHost: ScriptJSHost

    public var context: JSContext { scriptHost.context }
    public var lastException: String? { scriptHost.lastException }

    public init(
        state: RuntimeEntityState = RuntimeEntityState(),
        observation: CanonicalRuntimeObservation = CanonicalRuntimeObservation()
    ) {
        self.state = state
        self.observation = observation
        self.scriptHost = ScriptJSHost(state: state)
        installCanonicalBridge()
    }

    /// Loads a graph through the production canonical compiler.
    public func load(_ graph: RCP3ScriptGraph) {
        scriptHost.load(CanonicalScriptGraphCompiler().compile(graph))
    }

    /// Seeds the mock ModelComponent with one material slot and its parameters.
    public func seedMaterial(slot: Int, parameters: [String: Any] = [:]) {
        guard let json = Self.json(parameters) else { return }
        scriptHost.load("__d3SeedMaterial(\(slot), \(json));")
    }

    /// Invokes a canonical lifecycle/runtime callback (`update`,
    /// `collisionBegan`, …). Event payload fields are visible to event output pins.
    public func dispatch(_ callback: String, payload: [String: Any] = [:]) {
        let payloadJSON = Self.json(payload) ?? "{}"
        let callbackJSON = Self.json(callback) ?? "\"\""
        observation.operations.append(.event(callback))
        scriptHost.load("if (typeof this[\(callbackJSON)] === 'function') this[\(callbackJSON)](\(payloadJSON));")
    }

    private func installCanonicalBridge() {
        let global = context.objectForKeyedSubscript("globalThis")
        let record: @convention(block) (String, JSValue) -> Void = { [weak observation] name, value in
            guard let observation else { return }
            switch name {
            case "getComponent": observation.operations.append(.getComponent(value.toString() ?? ""))
            case "setComponent": observation.operations.append(.setComponent(value.toString() ?? ""))
            case "addChild": observation.operations.append(.addChild(preservingWorldTransform: value.toBool()))
            case "getMaterial": observation.operations.append(.getMaterial(slot: Int(value.toInt32())))
            case "setMaterial": observation.operations.append(.setMaterial(slot: Int(value.toInt32())))
            case "getMaterialParameter": observation.operations.append(.getMaterialParameter(value.toString() ?? ""))
            case "setMaterialParameter": observation.operations.append(.setMaterialParameter(value.toString() ?? ""))
            default: break
            }
        }
        global?.setObject(record, forKeyedSubscript: "__d3RecordCanonicalOperation" as NSString)
        scriptHost.load(Self.prelude)
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String else {
            return nil
        }
        if let string = value as? String {
            guard let data = try? JSONSerialization.data(withJSONObject: [string]),
                  let encoded = String(data: data, encoding: .utf8) else { return nil }
            return String(encoded.dropFirst().dropLast())
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8) else { return nil }
        return encoded
    }

    /// Minimal public-runtime-shaped objects. The component/material stores are
    /// generic; adding a compiler node that calls the same API requires no host hack.
    static let prelude = #"""
    (function(global) {
        const components = Object.create(null);
        const materials = Object.create(null);

        function typeName(type) {
            if (typeof type === "string") return type;
            if (type && type.__typeName) return type.__typeName;
            if (type && type.name) return type.name;
            return "UnknownComponent";
        }
        function record(name, value) { __d3RecordCanonicalOperation(name, value); }
        function makeMaterial(parameters) {
            return {
                parameters: Object.assign({}, parameters || {}),
                getParameter: function(name) {
                    record("getMaterialParameter", String(name));
                    return this.parameters[name];
                },
                setParameter: function(name, value) {
                    record("setMaterialParameter", String(name));
                    this.parameters[name] = value;
                }
            };
        }
        const modelComponent = {
            __typeName: "ModelComponent",
            getMaterial: function(slot) {
                record("getMaterial", slot);
                return materials[slot] || null;
            },
            setMaterial: function(material, slot) {
                record("setMaterial", slot);
                materials[slot] = material;
            }
        };
        components.ModelComponent = modelComponent;

        entity.position = entity.transform.translation;
        entity.orientation = entity.transform.rotation;
        entity.scale = entity.transform.scale;
        Object.defineProperty(entity, "position", {
            get: function() { return entity.transform.translation; },
            set: function(v) { entity.transform.translation = v; }
        });
        Object.defineProperty(entity, "orientation", {
            get: function() { return entity.transform.rotation; },
            set: function(v) { entity.transform.rotation = v; }
        });
        Object.defineProperty(entity, "scale", {
            get: function() { return entity.transform.scale; },
            set: function(v) { entity.transform.scale = v; }
        });
        entity.getComponent = function(type) {
            const name = typeName(type);
            record("getComponent", name);
            return components[name] || null;
        };
        entity.setComponent = function(component) {
            const name = typeName(component);
            record("setComponent", name);
            components[name] = component;
        };
        entity.addChild = function(child, preserving) {
            record("addChild", !!preserving);
            (this.children || (this.children = [])).push(child);
        };
        entity.removeChild = function(child) {
            this.children = (this.children || []).filter(function(x) { return x !== child; });
        };
        entity.setParent = function(parent, preserving) { parent.addChild(this, preserving); };
        entity.removeFromParent = function() {};

        function componentType(name) {
            function Component() { this.__typeName = name; }
            Component.Type = { __typeName: name };
            return Component;
        }
        const RealityKit = {
            ModelComponent: componentType("ModelComponent"),
            InputTargetComponent: componentType("InputTargetComponent")
        };
        const moduleProxy = new Proxy(RealityKit, {
            get: function(target, name) {
                if (!(name in target)) target[name] = componentType(String(name));
                return target[name];
            }
        });
        global.require = function(name) {
            if (name === "RealityKit") return moduleProxy;
            if (name === "Math3D") return {};
            return {};
        };
        global.entity = entity;
        global.__d3SeedMaterial = function(slot, parameters) {
            materials[slot] = makeMaterial(parameters);
        };
        if (!console.error) console.error = console.log;
    })(this);
    """#
}
