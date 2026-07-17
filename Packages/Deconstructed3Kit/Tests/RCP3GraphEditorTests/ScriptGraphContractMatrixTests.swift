import Foundation
import Testing
@testable import RCP3GraphEditor

@Suite struct ScriptGraphContractMatrixTests {
    @Test func canonicalMatrixClosesTheRCP3CreatorUniverse() throws {
        let matrix = ScriptGraphContractMatrix.make()

        #expect(matrix.baseline == "reality-composer-pro-3")
        #expect(matrix.schemaVersion == 2)
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

    @Test func RCP3ResultsBindOnlyToTheExactDigestNamedProject() throws {
        let matrix = ScriptGraphContractMatrix.make()
        let item = try #require(matrix.cases.first)
        let unrelated = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            results: [.init(project: "/tmp/stale.realitycomposerpro", result: "success")]
        )
        #expect(unrelated.cases.first?.rcp3RuntimeCertification.status == .notRecorded)

        let passed = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            results: [.init(
                project: "/tmp/\(item.certificationProjectName)",
                result: "success"
            )]
        )
        #expect(passed.cases.first?.rcp3AuthoringCertification.status == .pass)
        #expect(passed.cases.first?.rcp3RuntimeCertification.status == .pass)
        #expect(passed.cases.first?.rcp3RuntimeCertification.applicationBuild == "build")
        #expect(passed.metrics.first { $0.id == "rcp3-runtime-certification" }?.numerator == 1)

        let runtimeFailure = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            results: [.init(
                project: item.certificationProjectName,
                result: "failure"
            )]
        )
        #expect(runtimeFailure.cases.first?.rcp3AuthoringCertification.status == .pass)
        #expect(runtimeFailure.cases.first?.rcp3RuntimeCertification.status == .fail)

        let validationFailure = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            results: [.init(
                project: item.certificationProjectName,
                result: "failure",
                validationErrors: ["bad pin"]
            )]
        )
        #expect(validationFailure.cases.first?.rcp3AuthoringCertification.status == .fail)
        #expect(validationFailure.cases.first?.rcp3RuntimeCertification.status == .fail)
    }

    @Test func authoringSmokeNeverClaimsSubjectRuntimeEvidence() throws {
        let matrix = ScriptGraphContractMatrix.make()
        let item = try #require(matrix.cases.first)

        let passed = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            mode: .authoringSmoke,
            results: [.init(project: item.certificationProjectName, result: "success")]
        )
        #expect(passed.cases.first?.rcp3AuthoringCertification.status == .pass)
        #expect(passed.cases.first?.rcp3RuntimeCertification.status == .notRecorded)
        #expect(passed.metrics.first { $0.id == "rcp3-authoring-certification" }?.numerator == 1)
        #expect(passed.metrics.first { $0.id == "rcp3-runtime-certification" }?.numerator == 0)

        let harnessFailure = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            mode: .authoringSmoke,
            results: [.init(project: item.certificationProjectName, result: "failure")]
        )
        #expect(harnessFailure.cases.first?.rcp3AuthoringCertification.status == .pass)
        #expect(harnessFailure.cases.first?.rcp3RuntimeCertification.status == .notRecorded)

        let validationFailure = matrix.applyingRCP3Results(
            applicationVersion: "3.0",
            applicationBuild: "build",
            mode: .authoringSmoke,
            results: [.init(
                project: item.certificationProjectName,
                result: "failure",
                validationErrors: ["bad pin"]
            )]
        )
        #expect(validationFailure.cases.first?.rcp3AuthoringCertification.status == .fail)
        #expect(validationFailure.cases.first?.rcp3RuntimeCertification.status == .notRecorded)
    }
}
