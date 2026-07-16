import Foundation
import RCP3Certification

private func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "init" {
    arguments.removeFirst()
    guard arguments.count == 1 else {
        fail("usage: rcp3-certify init <certification-root>")
    }
    do {
        let root = URL(filePath: arguments[0], directoryHint: .isDirectory)
        try RCP3CertificationManifest.write(to: root)
        print(root.appending(path: RCP3CertificationManifest.filename).path)
        exit(0)
    } catch {
        fail(String(describing: error))
    }
}
guard let rootPath = arguments.first, !rootPath.hasPrefix("-") else {
    fail("usage: rcp3-certify <certification-root> [--app <RCP3.app>] [--timeout <seconds>] [--output <evidence.json>]\n       rcp3-certify init <certification-root>")
}
arguments.removeFirst()

var applicationPath = "/Applications/RealityComposerPro.app"
var timeout: TimeInterval = 300
var outputPath: String?
while !arguments.isEmpty {
    let option = arguments.removeFirst()
    guard let value = arguments.first else { fail("missing value for \(option)") }
    arguments.removeFirst()
    switch option {
    case "--app": applicationPath = value
    case "--timeout":
        guard let parsed = TimeInterval(value), parsed > 0 else { fail("invalid timeout: \(value)") }
        timeout = parsed
    case "--output": outputPath = value
    default: fail("unknown option: \(option)")
    }
}

do {
    let evidence = try RCP3CertificationRunner().certify(.init(
        certificationRoot: URL(filePath: rootPath, directoryHint: .isDirectory),
        applicationURL: URL(filePath: applicationPath, directoryHint: .isDirectory),
        timeoutSeconds: timeout
    ))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(evidence) + Data("\n".utf8)
    if let outputPath {
        try data.write(to: URL(filePath: outputPath), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
    }
    exit(evidence.outcome == .passed ? 0 : 1)
} catch {
    fail(String(describing: error))
}
