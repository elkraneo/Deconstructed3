import Testing
import TMFormat

@Suite struct TMParserTests {
    @Test func parsesBareTopLevelObject() throws {
        let text = """
        __type: "tm_entity"
        __uuid: "abc-123"
        name: "world"
        count: 3
        flag: true
        """
        let object = try #require(try TM.parse(text).objectValue)
        #expect(object.type == "tm_entity")
        #expect(object.uuid == "abc-123")
        #expect(object.name == "world")
        #expect(object["count"]?.doubleValue == 3)
        #expect(object["flag"]?.boolValue == true)
    }

    @Test func parsesNestedObjectsAndArrays() throws {
        let text = """
        components: [
          {
            __type: "tm_transform_component"
            local_scale: {
              __uuid: "s1"
            }
          }
        ]
        """
        let object = try #require(try TM.parse(text).objectValue)
        let components = try #require(object["components"]?.arrayValue)
        #expect(components.count == 1)
        let component = try #require(components[0].objectValue)
        #expect(component.type == "tm_transform_component")
        #expect(component["local_scale"]?.objectValue?.uuid == "s1")
    }

    @Test func parsesBracedRootObject() throws {
        let object = try #require(try TM.parse(#"{ name: "x" }"#).objectValue)
        #expect(object.name == "x")
    }

    @Test func parsesTopLevelArray() throws {
        let text = """
        [
          { name: "A" }
          { name: "B" }
        ]
        """
        let array = try #require(try TM.parse(text).arrayValue)
        #expect(array.count == 2)
        #expect(array[1].objectValue?.name == "B")
    }

    @Test func modelsPrototypeInstancedChild() throws {
        // The canonical "one box in an empty scene" shape.
        let text = """
        __type: "tm_entity"
        name: "world"
        children: [
          {
            __prototype_type: "tm_entity"
            __prototype_uuid: "05fe482f"
            name: "box"
          }
        ]
        """
        let world = try #require(try TM.parse(text).objectValue)
        let children = try #require(world["children"]?.arrayValue)
        let box = try #require(children.first?.objectValue)
        #expect(box.name == "box")
        #expect(box.prototypeType == "tm_entity")
        #expect(box.prototypeUUID == "05fe482f")
    }

    @Test func preservesNumberLexeme() throws {
        let object = try #require(try TM.parse("g: -9.8100004196166992").objectValue)
        #expect(object["g"]?.numberLexeme == "-9.8100004196166992")
        #expect(object["g"]?.doubleValue == -9.8100004196166992)
    }

    @Test func failsOnMissingColon() {
        #expect(throws: TMParseError.self) {
            try TM.parse(#"name "x""#)
        }
    }

    @Test func failsOnUnterminatedString() {
        #expect(throws: TMParseError.self) {
            try TM.parse(#"name: "x"#)
        }
    }
}
