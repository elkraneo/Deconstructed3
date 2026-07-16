import CryptoKit
import Foundation

enum RCP3TestReportParser {
    private static let knownStatuses: Set<String> = [
        "success", "passed", "failure", "failed", "skipped", "not_executed",
        "syntax_error", "unrelated_failure",
    ]
    private static let statusKeys: Set<String> = ["status", "result", "outcome"]

    static func parse(_ data: Data) throws -> RCP3TestReportSummary {
        let object = try JSONSerialization.jsonObject(with: data)
        var statuses: [String: Int] = [:]
        var unknown: [String: Int] = [:]
        var validationErrors = 0
        walk(
            object,
            key: nil,
            statuses: &statuses,
            unknown: &unknown,
            validationErrors: &validationErrors
        )
        return RCP3TestReportSummary(
            statusCounts: statuses,
            unknownStatusCounts: unknown,
            validationErrorCount: validationErrors,
            sha256: SHA256.hash(data: data).hexString
        )
    }

    private static func walk(
        _ value: Any,
        key: String?,
        statuses: inout [String: Int],
        unknown: inout [String: Int],
        validationErrors: inout Int
    ) {
        if let dictionary = value as? [String: Any] {
            for (childKey, childValue) in dictionary {
                let normalizedKey = normalize(childKey)
                if normalizedKey.contains("validation") && normalizedKey.contains("error") {
                    validationErrors += nonemptyCount(childValue)
                }
                walk(
                    childValue,
                    key: normalizedKey,
                    statuses: &statuses,
                    unknown: &unknown,
                    validationErrors: &validationErrors
                )
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(
                    child,
                    key: key,
                    statuses: &statuses,
                    unknown: &unknown,
                    validationErrors: &validationErrors
                )
            }
        } else if let string = value as? String {
            let normalized = normalize(string)
            if knownStatuses.contains(normalized) {
                statuses[normalized, default: 0] += 1
            } else if let key, statusKeys.contains(key), !normalized.isEmpty {
                unknown[normalized, default: 0] += 1
            }
        }
    }

    private static func nonemptyCount(_ value: Any) -> Int {
        if let array = value as? [Any] { return array.count }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty ? 0 : dictionary.count }
        if let string = value as? String { return string.isEmpty ? 0 : 1 }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
