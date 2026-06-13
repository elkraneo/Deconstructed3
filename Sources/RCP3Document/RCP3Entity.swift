import TMFormat

/// A display-oriented projection of a `tm_entity` object: name, type, attached
/// component types, and recursively-projected children.
public struct RCP3Entity: Equatable, Sendable {
    public let name: String
    /// `__type`, or the `__prototype_type` when the entity is a prototype instance.
    public let type: String?
    public let uuid: String?
    public let prototypeUUID: String?
    public let componentTypes: [String]
    public let children: [RCP3Entity]

    public init(_ object: TMObject) {
        name = object.name ?? ""
        type = object.type ?? object.prototypeType
        uuid = object.uuid
        prototypeUUID = object.prototypeUUID

        var components: [String] = []
        for key in ["components", "components__instantiated"] {
            guard let array = object[key]?.arrayValue else { continue }
            for value in array {
                guard let component = value.objectValue else { continue }
                if let t = component.type ?? component.prototypeType {
                    components.append(t)
                }
            }
        }
        componentTypes = components

        children = (object["children"]?.arrayValue ?? [])
            .compactMap { $0.objectValue.map(RCP3Entity.init) }
    }
}
