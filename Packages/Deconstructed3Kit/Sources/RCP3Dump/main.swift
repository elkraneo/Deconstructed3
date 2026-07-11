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
        let registeredNodeType: String?
    }
    let cases: [Case]
}

private func certificationGraph(
    for item: CertificationMatrix.Case,
    resolvedType: String? = nil
) -> RCP3ScriptGraph {
    let type = resolvedType ?? item.subject
    if let graph = ScriptGraphAuthoringRecipes.makeGraph(
        requestedType: type,
        label: item.mechanism,
        graphID: "certification-\(item.mechanism)"
    ) {
        return graph
    }
    let subjectID = UUID().uuidString
    let node = RCP3ScriptGraph.Node(id: subjectID, type: type, label: item.mechanism)

    let needsExecRoot = item.kind == "nodelib-fixture"
        || ScriptGraphNodeLibrary.spec(for: node.type)?.inputs.contains(where: \.isExec)
        ?? ScriptGraphNodeLibrary.dynamicPinPolicy(for: node.type)?.fixedInputs.contains(where: \.isExec)
        ?? false
    let root = RCP3ScriptGraph.Node(id: UUID().uuidString, type: "tm_update", label: "Certification Start")
    return RCP3ScriptGraph(
        id: "certification-\(item.mechanism)",
        nodes: needsExecRoot ? [root, node] : [node],
        wires: needsExecRoot ? [.init(id: UUID().uuidString, from: root.id, to: node.id)] : [],
        data: [],
        variables: []
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
            // The matrix carries an identity derived from the fixture's stable
            // uniqueID. Materialization proves the portable authoring surface;
            // canonical execution remains a separate same-process registration
            // certification tier.
            if item.kind == "nodelib-fixture", item.registeredNodeType == nil {
                print("SKIP\t\(item.id)\tmissing derived NodeLib identity")
                continue
            }
            let resolvedType = item.registeredNodeType ?? item.subject
            let graph = certificationGraph(for: item, resolvedType: resolvedType)
            let asset = try bundle.createScriptGraphAsset(
                named: certificationAssetName(index: index, mechanism: item.mechanism)
            )
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: graph),
                toAssetWithRootUUID: asset.id,
                in: bundle.url
            )
            print("\(asset.name)\t\(asset.id)\t\(resolvedType)\t\(graph.nodes.count) nodes")
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
