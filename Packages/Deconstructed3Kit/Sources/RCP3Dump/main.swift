import Foundation
import RCP3Document

// Headless dev tool: print the scene-entity tree of a `.realitycomposerpro` bundle.
//   swift run rcp3-dump <path/to/Name.realitycomposerpro>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: rcp3-dump <path/to/Name.realitycomposerpro>\n".utf8))
    exit(2)
}

let url = URL(filePath: arguments[1])

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
    if let count = bundle.typeCount { print("schema types: \(count)") }
    print("root: \(url.lastPathComponent)")
    dump(bundle.entity, depth: 0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
