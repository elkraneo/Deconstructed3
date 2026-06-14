// Rendering/display RealityKit components and their scriptable properties.
// Property connector names are the public RealityKit property names (camelCase);
// display names are Title Case. Verify the exposed subset against RCP 3.
extension ScriptGraphNodeLibrary {
    static let renderingComponents: [ComponentSpec] = [
        ComponentSpec(name: "ModelComponent", properties: [
            .data("mesh", "Mesh"),
            .data("materials", "Materials"),
            .data("boundsMargin", "Bounds Margin"),
        ]),
        ComponentSpec(name: "OpacityComponent", properties: [
            .data("opacity", "Opacity"),
        ]),
        ComponentSpec(name: "ModelSortGroupComponent", properties: [
            .data("group", "Group"),
            .data("order", "Order"),
        ]),
        ComponentSpec(name: "BillboardComponent", properties: [
            .data("blendFactor", "Blend Factor"),
        ]),
        ComponentSpec(name: "ModelDebugOptionsComponent", properties: [
            // visualizationMode is get-only in public RealityKit (set via init).
            // Readable for a Get Component node; not settable.
            .data("visualizationMode", "Visualization Mode"),
        ]),
        ComponentSpec(name: "AdaptiveResolutionComponent", properties: [
            // pixelsPerMeter is get-only in public RealityKit (read-only).
            .data("pixelsPerMeter", "Pixels Per Meter"),
        ]),
    ]
}
