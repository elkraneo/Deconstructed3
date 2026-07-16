import CryptoKit
import Foundation

public enum RCP3CertificationError: Error, CustomStringConvertible, Equatable {
    case missingCertificationRoot(String)
    case missingTestManifest(String)
    case missingApplicationExecutable(String)
    case invalidApplicationMetadata(String)
    case unsupportedApplicationVersion(String)
    case invalidTimeout

    public var description: String {
        switch self {
        case let .missingCertificationRoot(path): "Certification root is not a directory: \(path)"
        case let .missingTestManifest(path): "RCP3 test manifest is missing: \(path)"
        case let .missingApplicationExecutable(path): "RCP3 executable is missing or not executable: \(path)"
        case let .invalidApplicationMetadata(path): "RCP3 application metadata is invalid: \(path)"
        case let .unsupportedApplicationVersion(version): "Expected Reality Composer Pro 3, found version \(version)"
        case .invalidTimeout: "Timeout must be greater than zero."
        }
    }
}

public struct RCP3CertificationRunner: Sendable {
    private let executor: any RCP3CertificationProcessExecuting
    private let now: @Sendable () -> Date

    public init(
        executor: any RCP3CertificationProcessExecuting = FoundationProcessExecutor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executor = executor
        self.now = now
    }

    public func certify(_ plan: RCP3CertificationPlan) throws -> RCP3CertificationEvidence {
        let fileManager = FileManager.default
        let root = plan.certificationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let app = plan.applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RCP3CertificationError.missingCertificationRoot(root.path)
        }
        let manifestURL = root.appending(path: "test.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw RCP3CertificationError.missingTestManifest(manifestURL.path)
        }
        guard plan.timeoutSeconds > 0 else { throw RCP3CertificationError.invalidTimeout }

        let executable = app.appending(path: "Contents/MacOS/RealityComposerPro")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw RCP3CertificationError.missingApplicationExecutable(executable.path)
        }
        let application = try applicationIdentity(at: app)
        guard application.version.split(separator: ".").first == "3" else {
            throw RCP3CertificationError.unsupportedApplicationVersion(application.version)
        }

        let inputs = try inputManifest(root: root)
        let reportURL = root.appending(path: "test_report.json")
        if fileManager.fileExists(atPath: reportURL.path) {
            try fileManager.removeItem(at: reportURL)
        }

        let arguments = [
            "--headless",
            "--test", "script-graph-graph-tests",
            "--fixed-refresh-rate", "60",
            "--test-seed-state", "0xd3", "0xc3",
            "--crash-recovery", "false",
            "--no-analytics",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TM_SCRIPT_TEST_ASSETS_DIR"] = root.path
        let recordedEnvironment = ["TM_SCRIPT_TEST_ASSETS_DIR": root.path]
        let startedAt = now()
        let processResult = try executor.execute(.init(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: root,
            timeoutSeconds: plan.timeoutSeconds
        ))
        let endedAt = now()

        let combinedOutput = processResult.stdoutTail + "\n" + processResult.stderrTail
        let integrationCompletion: RCP3CertificationProcessEvidence.IntegrationCompletion
        if combinedOutput.contains("Script Graph integration tests ended unsuccessfully") {
            integrationCompletion = .failed
        } else if combinedOutput.contains("Script Graph integration tests ended successfully") {
            integrationCompletion = .succeeded
        } else {
            integrationCompletion = .missing
        }

        var reasons: [String] = []
        var report: RCP3TestReportSummary?
        if fileManager.fileExists(atPath: reportURL.path) {
            do {
                report = try RCP3TestReportParser.parse(Data(contentsOf: reportURL))
            } catch {
                reasons.append("RCP3 emitted a malformed test_report.json: \(error)")
            }
        } else {
            reasons.append("RCP3 did not emit a fresh test_report.json.")
        }
        if processResult.timedOut { reasons.append("RCP3 exceeded the certification timeout.") }
        if processResult.exitStatus != 0 {
            reasons.append("The outer RCP3 host exited with status \(processResult.exitStatus); the fresh Script Graph report remains authoritative.")
        }
        if let report {
            if report.failureCount > 0 {
                reasons.append("RCP3 reported \(report.failureCount) terminal test failure(s).")
            }
            if report.validationErrorCount > 0 {
                reasons.append("RCP3 reported \(report.validationErrorCount) validation error(s).")
            }
            if !report.unknownStatusCounts.isEmpty {
                reasons.append("RCP3 reported unknown test statuses: \(report.unknownStatusCounts.keys.sorted().joined(separator: ", ")).")
            }
            if report.successCount == 0 {
                reasons.append("RCP3 reported no successful Script Graph tests.")
            }
        }
        switch integrationCompletion {
        case .succeeded:
            break
        case .failed:
            reasons.append("RCP3 reported that Script Graph integration ended unsuccessfully.")
        case .missing:
            reasons.append("RCP3 did not report a successful Script Graph integration completion.")
        }

        let outcome: RCP3CertificationOutcome
        if processResult.timedOut
            || integrationCompletion == .failed
            || (report?.failureCount ?? 0) > 0
            || (report?.validationErrorCount ?? 0) > 0 {
            outcome = .failed
        } else if integrationCompletion != .succeeded
            || report == nil || report?.successCount == 0
            || !(report?.unknownStatusCounts.isEmpty ?? false) {
            outcome = .inconclusive
        } else {
            outcome = .passed
        }

        return RCP3CertificationEvidence(
            schemaVersion: 1,
            outcome: outcome,
            reasons: reasons,
            application: application,
            invocation: .init(
                executable: executable.path,
                arguments: arguments,
                environment: recordedEnvironment
            ),
            inputs: inputs,
            process: .init(
                exitStatus: processResult.exitStatus,
                timedOut: processResult.timedOut,
                integrationCompletion: integrationCompletion,
                stdoutByteCount: processResult.stdoutByteCount,
                stderrByteCount: processResult.stderrByteCount,
                stdoutTail: processResult.stdoutTail,
                stderrTail: processResult.stderrTail
            ),
            report: report,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func applicationIdentity(at applicationURL: URL) throws -> RCP3ApplicationIdentity {
        let infoURL = applicationURL.appending(path: "Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String,
              let build = dictionary["CFBundleVersion"] as? String,
              identifier == "com.apple.realitycomposerpro"
        else { throw RCP3CertificationError.invalidApplicationMetadata(infoURL.path) }
        return .init(bundleIdentifier: identifier, version: version, build: build)
    }

    private func inputManifest(root: URL) throws -> [RCP3CertificationInputDigest] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        )
        var result: [RCP3CertificationInputDigest] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard try fileURL.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let resolvedFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            let rootComponents = root.pathComponents
            let fileComponents = resolvedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { continue }
            let relativePath = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard relativePath != "test_report.json",
                  relativePath != "rcp3-certification.json",
                  !relativePath.hasPrefix(".rcp3-certification-")
            else { continue }
            let digest = try fileDigest(at: resolvedFileURL)
            result.append(.init(
                relativePath: relativePath,
                byteCount: digest.byteCount,
                sha256: digest.sha256
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func fileDigest(at url: URL) throws -> (byteCount: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            byteCount += Int64(chunk.count)
            hash.update(data: chunk)
        }
        return (byteCount, hash.finalize().hexString)
    }
}
