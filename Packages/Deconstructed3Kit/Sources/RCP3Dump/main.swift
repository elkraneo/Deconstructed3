import Foundation
import RCP3Document
import RCP3GraphEditor
import TMFormat

// Headless dev tool: print the scene-entity tree of a `.realitycomposerpro` bundle.
//   swift run rcp3-dump <path/to/Name.realitycomposerpro>
// Materialize the complete certification corpus as real Script Graph assets:
//   swift run rcp3-dump export-corpus <path/to/Name.realitycomposerpro>
// Materialize the generated mechanism matrix as one minimal graph per case:
//   swift run rcp3-dump export-certification <project> <matrix.json>

let arguments = CommandLine.arguments
guard arguments.count == 2
    || (arguments.count == 3 && arguments[1] == "export-corpus")
    || (arguments.count == 4 && arguments[1] == "export-certification")
else {
    FileHandle.standardError.write(Data("""
    usage:
      rcp3-dump <path/to/Name.realitycomposerpro>
      rcp3-dump export-corpus <path/to/Name.realitycomposerpro>
      rcp3-dump export-certification <path/to/Name.realitycomposerpro> <path/to/matrix.json>
    """.utf8))
    exit(2)
}

let command = arguments.count > 2 ? arguments[1] : "dump"
let url = URL(filePath: arguments[command == "dump" ? 1 : 2])

private struct CertificationMatrix: Decodable {
    struct Case: Decodable {
        let id: String
        let kind: String
        let mechanism: String
        let subject: String
    }
    let cases: [Case]
}

private func certificationGraph(for item: CertificationMatrix.Case) -> RCP3ScriptGraph {
    let stringHash = TMHash.murmur64a("String")
    let floatHash = TMHash.murmur64a("Float")
    // RKS hashes concrete generic types, not the bare container spelling. This is
    // RCP's canonical type identity for Swift.Array<Swift.String>, captured by
    // selecting String in the Array Type inspector and saving the graph.
    let stringArrayHash: UInt64 = 0xa147db4e70aa455c
    let subjectID = UUID().uuidString

    var node = RCP3ScriptGraph.Node(id: subjectID, type: item.subject, label: item.mechanism)
    var variables: [RCP3ScriptGraph.Variable] = []
    var data: [RCP3ScriptGraph.DataLiteral] = []

    switch item.subject {
    case "tm_constant":
        // The generic Constant node is deprecated in RCP 3. Use the supported,
        // explicitly typed Bool constructor captured from RCP authoring.
        node = .init(id: subjectID, type: "tm_make_bool", label: item.mechanism)
        data.append(.init(
            id: UUID().uuidString,
            toNode: subjectID,
            toPin: TMHash.murmur64a("initial_value"),
            value: .bool(true)
        ))
    case "tm_break_anchoring_component_target":
        // Enum Make/Break nodes expose their schema-derived pins only after an
        // authored case selection. Plane exercises the widest Target payload.
        node.enumSelection = ScriptGraphNodeLibrary.enumSelection(
            for: item.subject,
            caseName: "plane"
        )
    case "tm_array_for_each":
        node.dynamicConnectorSettings = .init(
            // For Each uses the direct dynamic-connector settings object. Only
            // Array Create wraps it in `tm_array_create_node_settings`.
            container: .direct,
            inputs: [.init(name: "array", displayName: "Array", typeHash: stringArrayHash, order: 0)],
            outputs: [.init(name: "element", displayName: "Element", typeHash: stringHash, order: 0)]
        )
    case "tm_get_material_parameter", "tm_set_material_parameter_v2", "tm_modify_any_material":
        node.materialSettings = .init(
            typeHash: TMHash.murmur64a("PhysicallyBasedMaterial"),
            objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
            inputs: [.init(name: "roughness", typeHash: floatHash, editTypeHash: floatHash, isOptional: false)],
            outputs: [.init(name: "roughness", typeHash: floatHash, editTypeHash: floatHash, isOptional: false)]
        )
    case "tm_get_variable_node", "tm_variable_add":
        let variable = RCP3ScriptGraph.Variable(
            uuid: UUID().uuidString,
            name: "Certification Value",
            typeHash: 0x3c2f3d0fe92dd9a0,
            editHash: 0x0ef2dd9a55accbe4,
            dataType: "tm_double"
        )
        variables = [variable]
        node.variableName = variable.name
        node.variableRefUUID = variable.uuid
    case "tm_get_component":
        data.append(.init(
            id: UUID().uuidString,
            toNode: subjectID,
            toPin: TMHash.murmur64a("component_type"),
            valueType: "re_scripting_graph_component_type",
            valueHash: TMHash.murmur64a("Transform")
        ))
    default:
        break
    }

    // Imported NodeLib nodes are opaque at graph level. Giving the fixture node a
    // typed interface makes the import/export case useful even before registration.
    if item.kind == "nodelib-fixture" {
        node = .init(
            id: subjectID,
            type: "certification_nodelib_fixture",
            label: item.subject,
            dynamicConnectorSettings: .init(
                container: .direct,
                inputs: [.init(name: "value", displayName: "Value", typeHash: stringHash, order: 0)],
                outputs: [.init(name: "result", displayName: "Result", typeHash: stringHash, order: 0)]
            )
        )
    }

    let needsExecRoot = ScriptGraphNodeLibrary.spec(for: node.type)?.inputs.contains(where: \.isExec)
        ?? ScriptGraphNodeLibrary.dynamicPinPolicy(for: node.type)?.fixedInputs.contains(where: \.isExec)
        ?? false
    let root = RCP3ScriptGraph.Node(id: UUID().uuidString, type: "tm_update", label: "Certification Start")
    return RCP3ScriptGraph(
        id: "certification-\(item.mechanism)",
        nodes: needsExecRoot ? [root, node] : [node],
        wires: needsExecRoot ? [.init(id: UUID().uuidString, from: root.id, to: node.id)] : [],
        data: data,
        variables: variables
    )
}

private func certificationAssetName(index: Int, mechanism: String) -> String {
    let safe = mechanism.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    return String(format: "Certification %02d ", index + 1) + String(safe)
}

func dump(_ entity: RCP3Entity, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    let name = entity.name.isEmpty ? "(unnamed)" : entity.name
    let components = entity.componentTypes.isEmpty
        ? ""
        : "  [\(entity.componentTypes.joined(separator: ", "))]"
    let prototype = entity.prototypeUUID.map { "  ←proto \($0.prefix(8))" } ?? ""
    print("\(pad)• \(name)  <\(entity.type ?? "?")>\(components)\(prototype)")
    for child in entity.children {
        dump(child, depth: depth + 1)
    }
}

do {
    let bundle = try RCP3Bundle.open(url)
    if command == "export-corpus" {
        for example in ScriptGraphExamples.all {
            let asset = try bundle.createScriptGraphAsset(named: example.name)
            let model = ScriptGraphEditorModel(graph: example.graph)
            try ScriptGraphWriteBack.write(
                model: model,
                toAssetWithRootUUID: asset.id,
                in: bundle.url
            )
            print("\(asset.name)\t\(asset.id)\t\(example.graph.nodes.count) nodes")
        }
        exit(0)
    }
    if command == "export-certification" {
        let matrixURL = URL(filePath: arguments[3])
        let matrix = try JSONDecoder().decode(CertificationMatrix.self, from: Data(contentsOf: matrixURL))
        guard !matrix.cases.isEmpty else {
            throw NSError(
                domain: "RCP3Dump.Certification",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "certification matrix contains no cases"]
            )
        }
        for (index, item) in matrix.cases.enumerated() {
            let graph = certificationGraph(for: item)
            let asset = try bundle.createScriptGraphAsset(
                named: certificationAssetName(index: index, mechanism: item.mechanism)
            )
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: graph),
                toAssetWithRootUUID: asset.id,
                in: bundle.url
            )
            print("\(asset.name)\t\(asset.id)\t\(item.subject)\t\(graph.nodes.count) nodes")
        }
        exit(0)
    }
    if let count = bundle.typeCount { print("schema types: \(count)") }
    print("root: \(url.lastPathComponent)")
    dump(bundle.entity, depth: 0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
