import Foundation

public enum RCP3CertificationManifest {
    public static let filename = "test.json"

    /// Writes the exact RCP3 Script Graph integration-test root configuration.
    public static func write(to certificationRoot: URL) throws {
        let root = certificationRoot.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "script-graph-tests": [
                "excluded": [],
                "report_file": "%TM_SCRIPT_TEST_ASSETS_DIR%/test_report.json",
                "projects_dir": "%TM_SCRIPT_TEST_ASSETS_DIR%",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        try data.write(to: root.appending(path: filename), options: .atomic)
    }
}
