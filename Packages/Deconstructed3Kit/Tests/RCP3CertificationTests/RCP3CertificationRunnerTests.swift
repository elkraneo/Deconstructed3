import Foundation
import Testing

@testable import RCP3Certification

@Suite("RCP3 external certification")
struct RCP3CertificationRunnerTests {
    @Test("Successful fresh report and zero exit are required for a pass")
    func successfulReportPasses() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor { request in
            #expect(request.arguments == [
                "--headless", "--test", "script-graph-graph-tests",
                "--fixed-refresh-rate", "60",
                "--test-seed-state", "0xd3", "0xc3",
                "--crash-recovery", "false", "--no-analytics",
            ])
            #expect(request.environment["TM_SCRIPT_TEST_ASSETS_DIR"] == fixture.root.path)
            try Data(#"{"tests":[{"status":"success"}]}"#.utf8)
                .write(to: fixture.root.appending(path: "test_report.json"))
            return .init(
                exitStatus: 0, stdoutByteCount: successLine.utf8.count,
                stdoutTail: successLine
            )
        }

        let evidence = try RCP3CertificationRunner(executor: executor).certify(fixture.plan)
        #expect(evidence.outcome == .passed)
        #expect(evidence.report?.successCount == 1)
        #expect(evidence.inputs.map(\.relativePath) == ["payload.txt", "test.json"])
    }

    @Test("A stale report is removed and cannot produce a pass")
    func staleReportDoesNotPass() throws {
        let fixture = try Fixture()
        try Data(#"{"status":"success"}"#.utf8)
            .write(to: fixture.root.appending(path: "test_report.json"))
        let evidence = try RCP3CertificationRunner(
            executor: FakeExecutor { _ in .init(exitStatus: 0) }
        ).certify(fixture.plan)

        #expect(evidence.outcome == .inconclusive)
        #expect(evidence.report == nil)
    }

    @Test("Report failures and unknown statuses fail closed independently of host exit")
    func terminalOutcomesFailClosed() throws {
        let reports: [(String, Int32, RCP3CertificationOutcome)] = [
            (#"{"status":"failure"}"#, 0, .failed),
            (#"{"status":"success","validation_errors":["bad pin"]}"#, 0, .failed),
            (#"{"status":"success"}"#, 9, .passed),
            (#"{"status":"skipped"}"#, 0, .failed),
            (#"{"status":"future_state"}"#, 0, .inconclusive),
        ]
        for (json, exitStatus, expected) in reports {
            let fixture = try Fixture()
            let evidence = try RCP3CertificationRunner(
                executor: FakeExecutor { request in
                    try Data(json.utf8).write(
                        to: request.currentDirectoryURL.appending(path: "test_report.json")
                    )
                    return .init(exitStatus: exitStatus, stdoutTail: successLine)
                }
            ).certify(fixture.plan)
            #expect(evidence.outcome == expected)
        }
    }

    @Test("Input hashes are deterministic and generated outputs are excluded")
    func deterministicInputs() throws {
        let fixture = try Fixture()
        let executor = FakeExecutor { request in
            try Data(#"{"status":"success"}"#.utf8)
                .write(to: request.currentDirectoryURL.appending(path: "test_report.json"))
            return .init(exitStatus: 0, stdoutTail: successLine)
        }
        let runner = RCP3CertificationRunner(executor: executor)
        let first = try runner.certify(fixture.plan)
        let second = try runner.certify(fixture.plan)
        #expect(first.inputs == second.inputs)
        #expect(!first.inputs.contains { $0.relativePath == "test_report.json" })

        try Data("changed".utf8).write(to: fixture.root.appending(path: "payload.txt"))
        let third = try runner.certify(fixture.plan)
        #expect(first.inputs != third.inputs)
    }

    @Test("RCP3 project results remain individually attributable")
    func individualCaseResults() throws {
        let fixture = try Fixture()
        let report = #"{"projects":[{"project":"/fixtures/alpha.realitycomposerpro","tests":[{"test":"passes","result":"success","validation-errors":[]},{"test":"bad pin","result":"failure","validation-errors":["missing input"]}]}]}"#
        let evidence = try RCP3CertificationRunner(
            executor: FakeExecutor { request in
                try Data(report.utf8).write(
                    to: request.currentDirectoryURL.appending(path: "test_report.json")
                )
                return .init(exitStatus: 0, stdoutTail: successLine)
            }
        ).certify(fixture.plan)

        #expect(evidence.outcome == .failed)
        #expect(evidence.report?.cases == [
            .init(
                project: "/fixtures/alpha.realitycomposerpro",
                test: "bad pin",
                result: "failure",
                validationErrors: ["missing input"]
            ),
            .init(
                project: "/fixtures/alpha.realitycomposerpro",
                test: "passes",
                result: "success"
            ),
        ])
    }

    @Test("Wrong application major version is rejected before execution")
    func wrongVersionRejected() throws {
        let fixture = try Fixture(version: "4.0")
        do {
            _ = try RCP3CertificationRunner(
                executor: FakeExecutor { _ in Issue.record("executor should not run"); return .init(exitStatus: 0) }
            ).certify(fixture.plan)
            Issue.record("expected unsupported version")
        } catch let error as RCP3CertificationError {
            #expect(error == .unsupportedApplicationVersion("4.0"))
        }
    }

    @Test("Manifest writer emits the RCP3 integration root contract")
    func manifestWriter() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RCP3ManifestTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try RCP3CertificationManifest.write(to: root)
        let object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appending(path: "test.json"))
            ) as? [String: Any]
        )
        let settings = try #require(object["script-graph-tests"] as? [String: Any])
        #expect(settings["excluded"] as? [String] == [])
        #expect(settings["report_file"] as? String == "%TM_SCRIPT_TEST_ASSETS_DIR%/test_report.json")
        #expect(settings["projects_dir"] as? String == "%TM_SCRIPT_TEST_ASSETS_DIR%")
    }
}

private final class FakeExecutor: RCP3CertificationProcessExecuting, @unchecked Sendable {
    private let operation: (RCP3CertificationProcessRequest) throws -> RCP3CertificationProcessResult

    init(
        _ operation: @escaping (RCP3CertificationProcessRequest) throws -> RCP3CertificationProcessResult
    ) {
        self.operation = operation
    }

    func execute(
        _ request: RCP3CertificationProcessRequest
    ) throws -> RCP3CertificationProcessResult {
        try operation(request)
    }
}

private let successLine = "Script Graph integration tests ended successfully"

private final class Fixture {
    let base: URL
    let root: URL
    let app: URL

    var plan: RCP3CertificationPlan {
        .init(certificationRoot: root, applicationURL: app, timeoutSeconds: 1)
    }

    init(version: String = "3.0") throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "RCP3CertificationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "root", directoryHint: .isDirectory)
        app = base.appending(path: "RealityComposerPro.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(#"{"script-graph-tests":[]}"#.utf8).write(to: root.appending(path: "test.json"))
        try Data("fixture".utf8).write(to: root.appending(path: "payload.txt"))

        let executable = macOS.appending(path: "RealityComposerPro")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.apple.realitycomposerpro",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "test-build",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: app.appending(path: "Contents/Info.plist"))
    }

    deinit { try? FileManager.default.removeItem(at: base) }
}
