import Foundation
import Testing
@testable import RCP3GraphEditor

@Suite struct ScriptGraphContractMatrixTests {
    @Test func canonicalMatrixClosesTheRCP3CreatorUniverse() throws {
        let matrix = ScriptGraphContractMatrix.make()

        #expect(matrix.baseline == "reality-composer-pro-3")
        #expect(matrix.schemaVersion == 1)
        #expect(matrix.cases.count == 344)
        #expect(Set(matrix.cases.map(\.requestedType)).count == 344)
        #expect(matrix.cases.flatMap(\.pins).count == 1_226)

        let metrics = Dictionary(uniqueKeysWithValues: matrix.metrics.map { ($0.id, $0) })
        #expect(metrics["subject-contract-resolution"]?.numerator == 344)
        #expect(metrics["subject-contract-resolution"]?.denominator == 344)
        #expect(metrics["structural-validity"]?.numerator == 344)
        #expect(metrics["pin-direction-kind"]?.numerator == 1_226)
        #expect(metrics["pin-direction-kind"]?.denominator == 1_226)
        #expect(metrics["data-pin-concrete-type"]?.denominator == 1_048)
        #expect(metrics["input-data-presence"]?.denominator == 583)
        #expect(metrics["rcp3-authoring-certification"]?.numerator == 0)
        #expect(metrics["rcp3-runtime-certification"]?.numerator == 0)
    }

    @Test func metricsAccountForEveryGapAndPinIdentitiesAreUniquePerDirection() {
        let matrix = ScriptGraphContractMatrix.make()

        for metric in matrix.metrics {
            #expect(metric.numerator >= 0)
            #expect(metric.numerator <= metric.denominator)
            #expect(metric.gapIDs.count == metric.denominator - metric.numerator)
            #expect(Set(metric.gapIDs).count == metric.gapIDs.count)
        }
        for item in matrix.cases {
            let identities = item.pins.map {
                "\($0.direction):\($0.kind):\($0.connectorHash ?? $0.connectorName)"
            }
            #expect(Set(identities).count == identities.count, "\(item.requestedType)")
            #expect(item.serialization.fixtureDigest == item.fixtureDigest)
            #expect(item.compiler.fixtureDigest == item.fixtureDigest)
            #expect(item.rcp3AuthoringCertification.fixtureDigest == item.fixtureDigest)
            #expect(item.rcp3RuntimeCertification.fixtureDigest == item.fixtureDigest)
        }
    }

    @Test func JSONAndDigestsAreDeterministic() throws {
        let first = ScriptGraphContractMatrix.make()
        let second = ScriptGraphContractMatrix.make()
        #expect(first == second)
        #expect(first.catalogDigest == second.catalogDigest)
        #expect(first.cases.map(\.fixtureDigest) == second.cases.map(\.fixtureDigest))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(first) == encoder.encode(second))
    }
}
