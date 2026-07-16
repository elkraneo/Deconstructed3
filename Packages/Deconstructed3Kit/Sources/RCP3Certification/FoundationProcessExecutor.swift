import Darwin
import Foundation

public struct FoundationProcessExecutor: RCP3CertificationProcessExecuting {
    public init() {}

    public func execute(
        _ request: RCP3CertificationProcessRequest
    ) throws -> RCP3CertificationProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutCollector = BoundedOutputCollector()
        let stderrCollector = BoundedOutputCollector()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        try process.run()
        let deadline = Date().addingTimeInterval(request.timeoutSeconds)
        var timedOut = false
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let stdoutSnapshot = stdoutCollector.snapshot()
        let stderrSnapshot = stderrCollector.snapshot()
        return RCP3CertificationProcessResult(
            exitStatus: process.terminationStatus,
            timedOut: timedOut,
            stdoutByteCount: stdoutSnapshot.byteCount,
            stderrByteCount: stderrSnapshot.byteCount,
            stdoutTail: stdoutSnapshot.tail,
            stderrTail: stderrSnapshot.tail
        )
    }
}

private final class BoundedOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit = 64 * 1024
    private var byteCount = 0
    private var tail = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        byteCount += data.count
        tail.append(data)
        if tail.count > limit {
            tail.removeFirst(tail.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> (byteCount: Int, tail: String) {
        lock.lock()
        defer { lock.unlock() }
        return (byteCount, String(decoding: tail, as: UTF8.self))
    }
}
