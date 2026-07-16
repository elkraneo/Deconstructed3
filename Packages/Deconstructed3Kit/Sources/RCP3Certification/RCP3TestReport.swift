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
            sha256: SHA256.hash(data: data).hexString,
            cases: extractCases(object)
        )
    }

    private static func extractCases(_ object: Any) -> [RCP3TestReportSummary.CaseResult] {
        guard let root = object as? [String: Any],
              let projects = root["projects"] as? [[String: Any]]
        else { return [] }
        return projects.flatMap { project -> [RCP3TestReportSummary.CaseResult] in
            let projectName = project["project"] as? String ?? ""
            let tests = project["tests"] as? [[String: Any]] ?? []
            return tests.map { test in
                let result = ["result", "status", "outcome"]
                    .compactMap { test[$0] as? String }
                    .first.map(normalize) ?? ""
                return .init(
                    project: projectName,
                    test: test["test"] as? String ?? "",
                    result: result,
                    validationErrors: flattenedStrings(
                        test["validation-errors"] ?? test["validation_errors"]
                    )
                )
            }
        }.sorted {
            ($0.project, $0.test, $0.result) < ($1.project, $1.test, $1.result)
        }
    }

    private static func flattenedStrings(_ value: Any?) -> [String] {
        switch value {
        case let string as String:
            return string.isEmpty ? [] : [string]
        case let values as [Any]:
            return values.flatMap { flattenedStrings($0) }
        case let values as [String: Any]:
            return values.sorted(by: { $0.key < $1.key }).flatMap { key, value in
                flattenedStrings(value).map { "\(key): \($0)" }
            }
        case let number as NSNumber:
            return [number.stringValue]
        default:
            return []
        }
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
