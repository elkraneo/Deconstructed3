import Foundation
import RCP3Document

/// Type identities recovered from RCP 3's live `TypeManagement` registry.
///
/// Runtime hashes are canonical Script Graph identities. Editor hashes are a
/// separate registry facet and must never be synthesized from the type name.
/// This table intentionally contains only identities proven through the shipped
/// host ABI; applications may layer harvested project-specific identities on top.
public enum ScriptGraphTypeRegistry {
    public struct Identity: Sendable, Hashable, Identifiable {
        public let id: String
        public let typeHash: UInt64
        public let editHash: UInt64

        public init(id: String, typeHash: UInt64, editHash: UInt64) {
            self.id = id
            self.typeHash = typeHash
            self.editHash = editHash
        }

        public func connector(
            name: String,
            displayName: String? = nil,
            order: Double,
            optionality: UInt32 = 1,
            includeEditorIdentity: Bool = true
        ) -> RCP3ScriptGraph.Node.DynamicConnector {
            .init(
                name: name,
                displayName: displayName,
                typeHash: typeHash,
                editHash: includeEditorIdentity ? editHash : 0,
                order: order,
                optionality: optionality
            )
        }
    }

    public static let bool = Identity(id: "Bool", typeHash: 0xb4a23826b1bfcfc6, editHash: 0xaed3caa5c516d191)
    public static let string = Identity(id: "String", typeHash: 0x6dc93f04c4a9310e, editHash: 0xa84ae1fca1a3e0cb)
    public static let number = Identity(id: "Number", typeHash: 0x3c2f3d0fe92dd9a0, editHash: 0x0ef2dd9a55accbe4)
    public static let vector2 = Identity(id: "Vector2", typeHash: 0xb535d7f05b25297b, editHash: 0x5ea1bb7b6537de46)
    public static let vector3 = Identity(id: "Vector3", typeHash: 0xacb19c32c360b8b0, editHash: 0x8d1487af36b1e3e1)
    public static let vector4 = Identity(id: "Vector4", typeHash: 0x1c85011070fccc98, editHash: 0xdf81286b1233bab6)
    public static let matrix2x2 = Identity(id: "Matrix2x2", typeHash: 0xff093e8136386a0a, editHash: 0xf28735b2c996ac59)
    public static let matrix3x3 = Identity(id: "Matrix3x3", typeHash: 0xa2310ffa46bc59bb, editHash: 0xc67c260c9c733693)
    public static let entity = Identity(id: "Entity", typeHash: 0x11fef190dc0c34a1, editHash: 0xf04a971fe569b002)
    public static let quaternion = Identity(id: "Quaternion", typeHash: 0xc0151474cbd67fcc, editHash: 0xa4d2f46b41c9d717)
    public static let matrix4x4 = Identity(id: "Matrix4x4", typeHash: 0x32e0e9614b5964e2, editHash: 0x571323c7ad582d5f)
    public static let stringArray = Identity(id: "Array<String>", typeHash: 0xa147db4e70aa455c, editHash: 0)
    public static let physicallyBasedMaterial = Identity(id: "PhysicallyBasedMaterial", typeHash: 0xdb686b8dd1bb85e3, editHash: 0)

    public static let pickerCore: [Identity] = [
        bool, string, number, vector2, vector3, vector4, matrix2x2, matrix3x3, entity,
        quaternion, matrix4x4, stringArray, physicallyBasedMaterial,
    ]

    public static func identity(named name: String) -> Identity? {
        pickerCore.first { $0.id == name }
    }

    public static func identity(typeHash: UInt64) -> Identity? {
        pickerCore.first { $0.typeHash == typeHash }
    }
}
