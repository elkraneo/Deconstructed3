import Testing
import Foundation
import TMFormat

@Suite struct TMSpecialValueTests {
    @Test func parsesInfinityAndNaNAsNumbers() throws {
        let object = try #require(try TM.parse("""
        a: inf
        b: -inf
        c: nan
        d: -9.81
        e: 42
        f: notanumber
        """).objectValue)
        #expect(object["a"]?.numberLexeme == "inf")
        #expect(object["b"]?.numberLexeme == "-inf")
        #expect(object["c"]?.numberLexeme == "nan")
        #expect(object["a"]?.doubleValue == .infinity)
        #expect(object["b"]?.doubleValue == -.infinity)
        #expect(object["c"]?.doubleValue?.isNaN == true)
        #expect(object["d"]?.doubleValue == -9.81)
        #expect(object["e"]?.numberLexeme == "42")
        // A non-numeric bareword stays a symbol.
        if case .symbol(let s) = object["f"] { #expect(s == "notanumber") }
        else { Issue.record("expected symbol for non-numeric bareword") }
    }

    @Test func roundTripsInfinity() throws {
        let original = try TM.parse("x: inf\ny: -inf\n")
        #expect(try TM.parse(original.tmText()) == original)
    }

    /// The real 926-type schema, if the capture is present.
    static var typeIndexURL: URL? {
        let container = URL(filePath: #filePath)
            .deletingLastPathComponent()  // TMFormatTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .deletingLastPathComponent()  // source
            .deletingLastPathComponent()  // Deconstructed3 container
        let url = container.appending(path: "references/Empty/Empty.realitycomposerpro/__type_index.tm_meta")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func parsesRealTypeIndexSchema() throws {
        guard let url = Self.typeIndexURL else { return } // capture not present
        let value = try TM.parse(String(contentsOf: url, encoding: .utf8))
        let types = try #require(value.arrayValue)
        #expect(types.count >= 900)
        // Round-trips semantically too.
        #expect(try TM.parse(value.tmText()) == value)
    }
}
