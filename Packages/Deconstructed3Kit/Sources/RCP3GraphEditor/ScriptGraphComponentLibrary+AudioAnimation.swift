// Audio/animation/media RealityKit components and their scriptable properties.
// connectorName = public RealityKit property name (camelCase); displayName = Title Case.
extension ScriptGraphNodeLibrary {
    static let audioAnimationComponents: [ComponentSpec] = [
        // MARK: - Audio
        ComponentSpec(name: "AmbientAudioComponent", properties: [
            .data("gain", "Gain"),
        ]),
        ComponentSpec(name: "SpatialAudioComponent", properties: [
            .data("gain", "Gain"),
            .data("directLevel", "Direct Level"),
            .data("reverbLevel", "Reverb Level"),
            .data("directivity", "Directivity"),
            .data("distanceAttenuation", "Distance Attenuation"),
        ]),
        ComponentSpec(name: "ChannelAudioComponent", properties: [
            .data("gain", "Gain"),
        ]),
        ComponentSpec(name: "AudioLibraryComponent", properties: [
            .data("resources", "Resources"),
        ]),
        ComponentSpec(name: "AudioMixGroupsComponent", properties: []),

        // MARK: - Animation
        ComponentSpec(name: "AnimationGraphComponent", properties: [
            .data("graph", "Graph"),
        ]),
        ComponentSpec(name: "AnimationLibraryComponent", properties: [
            .data("defaultKey", "Default Key"),
            .data("defaultAnimation", "Default Animation"),
        ]),

        // MARK: - Media
        ComponentSpec(name: "ParticleEmitterComponent", properties: [
            .data("emitterShape", "Emitter Shape"),
            .data("emitterShapeSize", "Emitter Shape Size"),
            .data("birthLocation", "Birth Location"),
            .data("birthDirection", "Birth Direction"),
            .data("speed", "Speed"),
            .data("speedVariation", "Speed Variation"),
            .data("isEmitting", "Is Emitting"),
            .data("simulationState", "Simulation State"),
            .data("burstCount", "Burst Count"),
        ]),
        ComponentSpec(name: "VideoPlayerComponent", properties: [
            .data("desiredViewingMode", "Desired Viewing Mode"),
            .data("isPassthroughTintingEnabled", "Is Passthrough Tinting Enabled"),
            .data("desiredImmersiveViewingMode", "Desired Immersive Viewing Mode"),
            .data("portalSize", "Portal Size"),
        ]),
    ]
}
