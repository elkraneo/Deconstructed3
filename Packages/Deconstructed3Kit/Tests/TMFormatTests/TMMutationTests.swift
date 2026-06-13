import Testing
import TMFormat

@Suite struct TMMutationTests {
    // MARK: Flat member set

    @Test func settingExistingKeyRewritesInPlace() throws {
        let object = try #require(try TM.parse("""
        __type: "tm_entity"
        name: "world"
        flag: true
        """).objectValue)

        let updated = object.setting(.string("renamed"), forKey: "name")

        // Targeted member changed.
        #expect(updated.name == "renamed")
        // Siblings unchanged.
        #expect(updated.type == "tm_entity")
        #expect(updated["flag"]?.boolValue == true)
        // Order preserved (name stays in slot 1, not appended).
        #expect(updated.members.map(\.key) == ["__type", "name", "flag"])
        // Original is untouched (value semantics).
        #expect(object.name == "world")
    }

    @Test func settingNewKeyAppends() {
        let object = TMObject(members: [.init(key: "a", value: .number("1"))])
        let updated = object.setting(.string("z"), forKey: "b")
        #expect(updated.members.map(\.key) == ["a", "b"])
        #expect(updated["b"]?.stringValue == "z")
    }

    @Test func mutatingSetEditsInPlace() {
        var object = TMObject(members: [.init(key: "name", value: .string("a"))])
        object.set(.string("b"), forKey: "name")
        #expect(object.name == "b")
        #expect(object.members.count == 1)
    }

    @Test func settingNameConvenience() {
        let object = TMObject(members: [.init(key: "name", value: .string("old"))])
        #expect(object.settingName("new").name == "new")
    }

    @Test func removingKey() {
        let object = TMObject(members: [
            .init(key: "a", value: .number("1")),
            .init(key: "b", value: .number("2")),
        ])
        let updated = object.removing(key: "a")
        #expect(updated.members.map(\.key) == ["b"])
        #expect(object.removing(key: "missing").members.count == 2) // no-op
    }

    // MARK: Round-trip + mutation in memory

    @Test func roundTripsAfterMutation() throws {
        let original = try #require(try TM.parse("""
        __type: "tm_entity"
        name: "world"
        components: [
          { __type: "tm_transform_component"  local_scale: { __uuid: "s1" } }
        ]
        children: [
          { __prototype_type: "tm_entity"  __prototype_uuid: "05fe482f"  name: "box" }
        ]
        g: -9.8100004196166992
        """).objectValue)

        // parse → set a member → tmText → parse
        let mutated = original.settingName("renamed-world")
        let reparsed = try #require(try TM.parse(mutated.tmText()).objectValue)

        // Change present.
        #expect(reparsed.name == "renamed-world")
        // Siblings unchanged through the serialize/parse cycle.
        #expect(reparsed.type == "tm_entity")
        #expect(reparsed["g"]?.numberLexeme == "-9.8100004196166992")
        #expect(reparsed["components"] == original["components"])
        #expect(reparsed["children"] == original["children"])
    }

    // MARK: Path-based set (nested)

    @Test func settingNestedChildName() throws {
        let object = try #require(try TM.parse("""
        name: "world"
        children: [
          { name: "box" }
          { name: "sphere" }
        ]
        """).objectValue)

        let updated = try object.setting(.string("crate"), at: "children[1].name")

        let children = try #require(updated["children"]?.arrayValue)
        #expect(children[0].objectValue?.name == "box")   // sibling unchanged
        #expect(children[1].objectValue?.name == "crate") // target changed
        #expect(updated.name == "world")                  // parent unchanged
    }

    @Test func settingDeepNestedMember() throws {
        let object = try #require(try TM.parse("""
        name: "world"
        components: [
          { __type: "tm_transform_component"  local_scale: { __uuid: "s1" } }
        ]
        """).objectValue)

        let updated = try object.setting(.string("s2"), at: "components[0].local_scale.__uuid")
        let scale = try #require(try updated.value(at: "components[0].local_scale").objectValue)
        #expect(scale.uuid == "s2")
    }

    @Test func pathRoundTripsThroughSerialization() throws {
        let object = try #require(try TM.parse("""
        name: "world"
        children: [ { name: "box" } ]
        """).objectValue)

        let updated = try object.setting(.string("renamed"), at: "children[0].name")
        let reparsed = try #require(try TM.parse(updated.tmText()).objectValue)
        #expect(try reparsed.value(at: "children[0].name") == .string("renamed"))
    }

    @Test func pathStringParsing() {
        #expect(TMPath("children[0].name").steps == [.member("children"), .index(0), .member("name")])
        #expect(TMPath("a.b.c").steps == [.member("a"), .member("b"), .member("c")])
        #expect(TMPath("items[12]").steps == [.member("items"), .index(12)])
    }

    @Test func pathErrorsOnMissingMember() {
        let object = TMObject(members: [.init(key: "name", value: .string("x"))])
        #expect(throws: TMPathError.self) {
            try object.setting(.string("y"), at: "children[0].name")
        }
    }

    @Test func pathErrorsOnIndexOutOfBounds() throws {
        let object = try #require(try TM.parse("children: [ { name: \"box\" } ]").objectValue)
        #expect(throws: TMPathError.self) {
            try object.setting(.string("y"), at: "children[5].name")
        }
    }
}
