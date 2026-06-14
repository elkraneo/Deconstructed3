// Physics/collision RealityKit components and their scriptable properties.
// connectorName = public RealityKit property name (camelCase); displayName = Title Case.
extension ScriptGraphNodeLibrary {
    static let physicsComponents: [ComponentSpec] = [
        ComponentSpec(name: "PhysicsBodyComponent", properties: [
            .data("mode", "Mode"),
            .data("massProperties", "Mass Properties"),
            .data("material", "Material"),
            .data("isAffectedByGravity", "Is Affected By Gravity"),
            .data("linearDamping", "Linear Damping"),
            .data("angularDamping", "Angular Damping"),
            .data("isContinuousCollisionDetectionEnabled", "Is Continuous Collision Detection Enabled"),
            .data("isRotationLocked", "Is Rotation Locked"),
            .data("isTranslationLocked", "Is Translation Locked"),
        ]),
        ComponentSpec(name: "PhysicsMotionComponent", properties: [
            .data("linearVelocity", "Linear Velocity"),
            .data("angularVelocity", "Angular Velocity"),
        ]),
        ComponentSpec(name: "CollisionComponent", properties: [
            .data("shapes", "Shapes"),
            .data("mode", "Mode"),
            .data("filter", "Filter"),
            .data("collisionOptions", "Collision Options"),
            .data("isStatic", "Is Static"),
        ]),
        ComponentSpec(name: "CharacterControllerComponent", properties: [
            .data("height", "Height"),
            .data("radius", "Radius"),
            .data("skinWidth", "Skin Width"),
            .data("slopeLimit", "Slope Limit"),
            .data("stepLimit", "Step Limit"),
            .data("upVector", "Up Vector"),
            .data("collisionFilter", "Collision Filter"),
        ]),
        ComponentSpec(name: "CharacterControllerStateComponent", properties: [
            .data("velocity", "Velocity"),
            .data("isOnGround", "Is On Ground"),
        ]),
        ComponentSpec(name: "ForceEffectComponent", properties: [
            .data("effects", "Effects"),
            .data("simulationState", "Simulation State"),
        ]),
        ComponentSpec(name: "PhysicsJointsComponent", properties: [
            .data("joints", "Joints"),
        ]),
        ComponentSpec(name: "PhysicsSimulationComponent", properties: [
            .data("clock", "Clock"),
            .data("collisionOptions", "Collision Options"),
            .data("gravity", "Gravity"),
            .data("solverIterations", "Solver Iterations"),
        ]),
    ]
}
