import Testing
import RCP3Document
import RCP3GraphEditor
import RCP3Runtime

/// Honest, generated coverage accounting across the authoring and clean-room
/// compiler surfaces. A clean compile here is not RCP or RKS certification.
@Suite("Script Graph observable coverage")
struct ScriptGraphObservableCoverageTests {
    private static let curatedFamilies: [String: Set<String>] = [
        "event roots": ["tm_update", "tm_did_add", "tm_gesture_event_drag", "tm_gesture_event_tap"],
        "component access": ["tm_get_component", "tm_set_component"],
        "state": ["tm_get_variable_node", "tm_set_variable_node"],
        "value and math": [
            "tm_make_vector3", "tm_make_rotation", "tm_make_look_at_rotation",
            "tm_math_add", "tm_math_multiply", "tm_math_sin", "tm_math_cos",
        ],
        "control flow": ["tm_if", "tm_not", "tm_loop", "tm_delay", "tm_do_once"],
    ]

    private static func hasUnsupportedDiagnostic(_ javascript: String) -> Bool {
        javascript.contains("unsupported node:") || javascript.contains("/* unsupported:")
    }

    @Test("All 20 curated types belong to a behavioral family and compile on a wired scenario")
    func curatedFamilyMatrixIsComplete() {
        let curated = ScriptGraphExamples.coveredNodeTypes
        let classified = Self.curatedFamilies.values.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }

        #expect(curated.count == 20)
        #expect(classified == curated)
        #expect(Self.curatedFamilies.values.allSatisfy { !$0.isEmpty })

        for (family, types) in Self.curatedFamilies {
            for type in types {
                let scenarios = ScriptGraphExamples.all.filter { $0.requiredNodeTypes.contains(type) }
                #expect(!scenarios.isEmpty, "\(family)/\(type) has no wired scenario")
                #expect(scenarios.contains {
                    !Self.hasUnsupportedDiagnostic(
                        CanonicalScriptGraphCompiler().compile($0.graph)
                    )
                }, "\(family)/\(type) has no clean compiler scenario")
            }
        }
    }

    @Test("Every palette type receives a generated result and context gaps remain explicit")
    func generatedPaletteCompilerGapReport() {
        let palette = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        let casesByType = Dictionary(
            uniqueKeysWithValues: ScriptGraphGeneratedCorpus.all.map { ($0.requestedType, $0) }
        )
        var clean: Set<String> = []
        var needsWiredContext: Set<String> = []

        for type in palette {
            guard let corpusCase = casesByType[type] else { continue }
            let javascript = CanonicalScriptGraphCompiler().compile(corpusCase.graph)
            if Self.hasUnsupportedDiagnostic(javascript) {
                needsWiredContext.insert(type)
            } else {
                clean.insert(type)
            }
        }

        #expect(palette.count >= 336)
        #expect(Set(casesByType.keys) == palette)
        #expect(clean.isDisjoint(with: needsWiredContext))
        #expect(clean.union(needsWiredContext) == palette)

        // Baseline delta, not a parity claim: minimal generated fixtures prove
        // authoring/serialization, but pure/value nodes often need a wired
        // consumer before the compiler can emit observable code. Curated wired
        // scenarios are accounted independently above.
        #expect(clean.count >= 83)
        #expect(needsWiredContext.count <= 253)
    }
}
