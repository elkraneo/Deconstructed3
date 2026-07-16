import Foundation

/// Creator-facing choices backed by the recovered RCP3 authoring registries.
public enum ScriptGraphAuthoringChoices {
    public static let componentTypeNames: [String] =
        ScriptGraphNodeLibrary.registeredComponents.map(\.name).sorted()

    public static let valueTypeNames: [String] =
        ScriptGraphTypeRegistry.pickerCore.map(\.id)

    public static let entityParameterTypeNames: [String] =
        ScriptGraphTypeRegistry.pickerCore.filter { $0.editHash != 0 }.map(\.id)

    public static func valueTypeName(typeHash: UInt64, editHash: UInt64? = nil) -> String? {
        ScriptGraphTypeRegistry.pickerCore.first {
            $0.typeHash == typeHash || (editHash != nil && $0.editHash == editHash)
        }?.id
    }

    public static func valueTypeName(editHash: UInt64) -> String? {
        ScriptGraphTypeRegistry.pickerCore.first { $0.editHash == editHash }?.id
    }
}
