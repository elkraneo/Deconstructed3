import Foundation
import RealityKit
import RealityKitScripting
import SwiftUI

/// Opt-in native-scene certification for an Apple-compiled NodeLib method.
///
/// Production never discovers private files. The app shell explicitly injects an
/// artifact URL when `D3_CASE11_SCRIPT_PATH` is present in its environment.
@MainActor
public struct Case11SceneRuntimeProbeView: View {
    private let artifactURL: URL
    @State private var result = "Waiting for the scripted entity to initialize…"

    public init(artifactURL: URL) {
        self.artifactURL = artifactURL
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Case 11 — NodeLib scene-runtime probe")
                .font(.headline)
            Text(result)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            ProbeRealityView(artifactURL: artifactURL, result: $result)
        }
        .padding()
    }
}

@MainActor
private struct ProbeRealityView: View {
    let artifactURL: URL
    @Binding var result: String

    var body: some View {
        RealityView { content in
            let root = ModelEntity(
                mesh: .generateBox(size: 0.05),
                materials: [SimpleMaterial(color: .gray, isMetallic: false)]
            )
            root.name = "Case11Root"

            let source = Entity()
            source.name = "Case11Source"
            let staging = Entity()
            staging.name = "Case11Staging"
            let child = ModelEntity(
                mesh: .generateBox(size: 0.1),
                materials: [SimpleMaterial(color: .green, isMetallic: false)]
            )
            child.name = "Case11Child"
            staging.addChild(child)
            root.addChild(source)
            root.addChild(staging)

            guard let appleProgram = try? String(contentsOf: artifactURL, encoding: .utf8),
                  let sourceCode = Case11ProbeSource.runtimeSource(from: appleProgram) else {
                result = "FAIL: artifact is missing the registered Case 11 emitter"
                content.add(root)
                return
            }

            do {
                try RKS.validateScript(sourceCode)
            } catch {
                result = "FAIL: RKS rejected the Apple emitter: \(error)"
                content.add(root)
                return
            }

            root.components.set(ScriptingComponent(source: sourceCode))
            content.add(root)

            Task { @MainActor in
                // Give the signed app's RKS system time to initialize this target.
                try? await Task.sleep(for: .seconds(2))
                root.send(name: Case11ProbeSource.eventName, with: [
                    "source": source,
                    "child": child,
                    "preservingWorldTransform": true,
                ])
                try? await Task.sleep(for: .seconds(1))
                result = child.parent === source
                    ? "PASS: Apple-emitted addChild moved Case11Child under Case11Source"
                    : "FAIL: child remains under \(child.parent?.name ?? "nil")"
                print("Case 11 scene runtime: \(result)")
            }
        }
        .realityScripting()
    }
}

/// Extracts only Apple's registered method declaration from the compiler output.
/// The original graph intentionally supplies undefined Entity pins; this clean RKS
/// wrapper supplies real scene Entities through the public event bridge.
enum Case11ProbeSource {
    static let functionName = "node__node_17854906811712824314"
    static let eventName = "case11Execute"

    static func runtimeSource(from appleProgram: String) -> String? {
        let marker = "const \(functionName) ="
        guard let start = appleProgram.range(of: marker) else { return nil }
        let emitter = String(appleProgram[start.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard emitter.contains("addChild") else { return nil }
        return #"""
        const RealityKit = require("RealityKit");
        """# + "\n" + emitter + "\n" + #"""
        this.entity.on("case11Execute", (event) => {
            node__node_17854906811712824314(
                event.source,
                event.child,
                event.preservingWorldTransform
            );
        });
        """#
    }
}
