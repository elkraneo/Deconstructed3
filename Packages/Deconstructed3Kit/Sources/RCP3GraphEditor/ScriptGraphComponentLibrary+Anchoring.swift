// Anchoring/interaction/scene RealityKit components and their scriptable properties.
// connectorName = public RealityKit property name (camelCase); displayName = Title Case.
extension ScriptGraphNodeLibrary {
    static let anchoringComponents: [ComponentSpec] = [
        ComponentSpec(name: "AnchoringComponent", properties: [
            .data("target", "Target"),
            .data("trackingMode", "Tracking Mode"),
            .data("physicsSimulation", "Physics Simulation"),
        ]),
        ComponentSpec(name: "InputTargetComponent", properties: [
            .data("allowedInputTypes", "Allowed Input Types"),
            .data("isEnabled", "Is Enabled"),
        ]),
        ComponentSpec(name: "HoverEffectComponent", properties: [
            .data("hoverEffect", "Hover Effect"),
        ]),
        ComponentSpec(name: "GeometricPinsComponent", properties: [
            .data("pins", "Pins"),
        ]),
        ComponentSpec(name: "ReferenceComponent", properties: [
            .data("reference", "Reference"),
            .data("loadingPolicy", "Loading Policy"),
            .data("state", "State"),
        ]),
        ComponentSpec(name: "SynchronizationComponent", properties: [
            .data("identifier", "Identifier"),
            .data("isOwner", "Is Owner"),
            .data("ownershipTransferMode", "Ownership Transfer Mode"),
        ]),
        ComponentSpec(name: "PortalCrossingComponent", properties: []),
        ComponentSpec(name: "AccessibilityComponent", properties: [
            .data("isAccessibilityElement", "Is Accessibility Element"),
            .data("label", "Label"),
            .data("value", "Value"),
            .data("traits", "Traits"),
            .data("systemActions", "System Actions"),
            .data("customActions", "Custom Actions"),
            .data("customContent", "Custom Content"),
            .data("customRotors", "Custom Rotors"),
        ]),
        ComponentSpec(name: "BlendShapeWeightsComponent", properties: [
            .data("weightSet", "Weight Set"),
        ]),
        ComponentSpec(name: "SkeletalPosesComponent", properties: [
            .data("poses", "Poses"),
        ]),
    ]
}
