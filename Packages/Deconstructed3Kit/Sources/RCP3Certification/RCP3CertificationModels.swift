import Foundation

public struct RCP3CertificationPlan: Sendable, Equatable {
    public var certificationRoot: URL
    public var applicationURL: URL
    public var timeoutSeconds: TimeInterval

    public init(
        certificationRoot: URL,
        applicationURL: URL = URL(
            filePath: "/Applications/RealityComposerPro.app",
            directoryHint: .isDirectory
        ),
        timeoutSeconds: TimeInterval = 300
    ) {
        self.certificationRoot = certificationRoot
        self.applicationURL = applicationURL
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum RCP3CertificationOutcome: String, Codable, Sendable {
    case passed
    case failed
    case inconclusive
}

public struct RCP3ApplicationIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let build: String
}

public struct RCP3CertificationInputDigest: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String
}

public struct RCP3CertificationInvocation: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
}

public struct RCP3CertificationProcessEvidence: Codable, Equatable, Sendable {
    public enum IntegrationCompletion: String, Codable, Sendable {
        case succeeded
        case failed
        case missing
    }

    public let exitStatus: Int32
    public let timedOut: Bool
    public let integrationCompletion: IntegrationCompletion
    public let stdoutByteCount: Int
    public let stderrByteCount: Int
    public let stdoutTail: String
    public let stderrTail: String
}

public struct RCP3TestReportSummary: Codable, Equatable, Sendable {
    public let statusCounts: [String: Int]
    public let unknownStatusCounts: [String: Int]
    public let validationErrorCount: Int
    public let sha256: String

    public var successCount: Int {
        (statusCounts["success"] ?? 0) + (statusCounts["passed"] ?? 0)
    }

    public var failureCount: Int {
        ["failure", "failed", "skipped", "not_executed", "syntax_error", "unrelated_failure"]
            .reduce(0) { $0 + (statusCounts[$1] ?? 0) }
    }
}

public struct RCP3CertificationEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let outcome: RCP3CertificationOutcome
    public let reasons: [String]
    public let application: RCP3ApplicationIdentity
    public let invocation: RCP3CertificationInvocation
    public let inputs: [RCP3CertificationInputDigest]
    public let process: RCP3CertificationProcessEvidence
    public let report: RCP3TestReportSummary?
    public let startedAt: Date
    public let endedAt: Date
}

public struct RCP3CertificationProcessRequest: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL
    public let timeoutSeconds: TimeInterval
}

public struct RCP3CertificationProcessResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let timedOut: Bool
    public let stdoutByteCount: Int
    public let stderrByteCount: Int
    public let stdoutTail: String
    public let stderrTail: String

    public init(
        exitStatus: Int32,
        timedOut: Bool = false,
        stdoutByteCount: Int = 0,
        stderrByteCount: Int = 0,
        stdoutTail: String = "",
        stderrTail: String = ""
    ) {
        self.exitStatus = exitStatus
        self.timedOut = timedOut
        self.stdoutByteCount = stdoutByteCount
        self.stderrByteCount = stderrByteCount
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public protocol RCP3CertificationProcessExecuting: Sendable {
    func execute(
        _ request: RCP3CertificationProcessRequest
    ) throws -> RCP3CertificationProcessResult
}
