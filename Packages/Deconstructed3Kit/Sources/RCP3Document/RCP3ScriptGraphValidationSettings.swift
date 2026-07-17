import Foundation
import TMFormat

/// RCP3's authoring settings for a `re_scripting_source_graph`.
///
/// These values live beside `graph` in the asset's `validation_settings` object.
/// The object may also carry identity and future members; callers that edit an
/// asset should patch its existing object rather than replace it wholesale.
public struct RCP3ScriptGraphValidationSettings: Equatable, Sendable {
    public var path: String
    public var isTest: Bool
    public var testTimeout: Double
    public var failOnTimeout: Bool
    public var flags: UInt32
    public var compileFlags: UInt32

    /// The defaults observed for an ordinary RCP3 Script Graph asset.
    public init(
        path: String = "",
        isTest: Bool = false,
        testTimeout: Double = 5,
        failOnTimeout: Bool = true,
        flags: UInt32 = 63,
        compileFlags: UInt32 = 1
    ) {
        self.path = path
        self.isTest = isTest
        self.testTimeout = testTimeout
        self.failOnTimeout = failOnTimeout
        self.flags = flags
        self.compileFlags = compileFlags
    }

    /// Reads an existing settings object, applying RCP3's observed defaults to
    /// members omitted by the text format.
    public init(tmObject object: TMObject) {
        path = object["path"]?.stringValue ?? ""
        isTest = object["is_test"]?.boolValue ?? false
        testTimeout = object["test_timeout"]?.doubleValue ?? 5
        failOnTimeout = object["fail_on_timeout"]?.boolValue ?? true
        flags = object["flags"]?.numberLexeme.flatMap(UInt32.init) ?? 63
        compileFlags = object["compile_flags"]?.numberLexeme.flatMap(UInt32.init) ?? 1
    }

    /// Settings for a graph registered with RCP3's integration-test host.
    public static let integrationTest = Self(isTest: true)
}
