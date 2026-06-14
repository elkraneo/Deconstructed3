// Lights/camera/IBL RealityKit components and their scriptable properties.
// connectorName = public RealityKit property name (camelCase); displayName = Title Case.
extension ScriptGraphNodeLibrary {
    static let lightingComponents: [ComponentSpec] = [
        // MARK: - Lights
        ComponentSpec(name: "DirectionalLightComponent", properties: [
            .data("color", "Color"),
            .data("intensity", "Intensity"),
        ]),
        ComponentSpec(name: "PointLightComponent", properties: [
            .data("color", "Color"),
            .data("intensity", "Intensity"),
            .data("attenuationRadius", "Attenuation Radius"),
            .data("attenuationFalloffExponent", "Attenuation Falloff Exponent"),
        ]),
        ComponentSpec(name: "SpotLightComponent", properties: [
            .data("color", "Color"),
            .data("intensity", "Intensity"),
            .data("innerAngleInDegrees", "Inner Angle In Degrees"),
            .data("outerAngleInDegrees", "Outer Angle In Degrees"),
            .data("attenuationRadius", "Attenuation Radius"),
            .data("attenuationFalloffExponent", "Attenuation Falloff Exponent"),
        ]),

        // MARK: - Cameras
        ComponentSpec(name: "PerspectiveCameraComponent", properties: [
            .data("near", "Near"),
            .data("far", "Far"),
            .data("fieldOfViewInDegrees", "Field Of View In Degrees"),
            .data("fieldOfViewOrientation", "Field Of View Orientation"),
        ]),
        ComponentSpec(name: "OrthographicCameraComponent", properties: [
            .data("near", "Near"),
            .data("far", "Far"),
            .data("scale", "Scale"),
            .data("scaleDirection", "Scale Direction"),
        ]),
        ComponentSpec(name: "ProjectiveTransformCameraComponent", properties: [
            .data("transform", "Transform"),
        ]),

        // MARK: - Shadows
        ComponentSpec(name: "GroundingShadowComponent", properties: [
            .data("castsShadow", "Casts Shadow"),
            .data("receivesShadow", "Receives Shadow"),
        ]),
        ComponentSpec(name: "DynamicLightShadowComponent", properties: [
            .data("castsShadow", "Casts Shadow"),
        ]),

        // MARK: - Image-Based Lighting
        ComponentSpec(name: "ImageBasedLightComponent", properties: [
            .data("source", "Source"),
            .data("inheritsRotation", "Inherits Rotation"),
            .data("intensityExponent", "Intensity Exponent"),
        ]),
        ComponentSpec(name: "ImageBasedLightReceiverComponent", properties: [
            .data("imageBasedLight", "Image Based Light"),
        ]),
        ComponentSpec(name: "EnvironmentLightingConfigurationComponent", properties: [
            .data("environmentLightingWeight", "Environment Lighting Weight"),
        ]),
        ComponentSpec(name: "VirtualEnvironmentProbeComponent", properties: [
            .data("source", "Source"),
            .data("influence", "Influence"),
        ]),
    ]
}
