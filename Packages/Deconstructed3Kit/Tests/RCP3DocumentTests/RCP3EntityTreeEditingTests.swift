import Foundation
import Testing
import TMFormat
@testable import RCP3Document

@Suite struct RCP3EntityTreeEditingTests {
    static let world = """
    __type: "tm_entity"
    __uuid: "00000000-0000-0000-0000-000000000001"
    name: "world"
    children: [
      {
        __uuid: "11111111-1111-1111-1111-111111111111"
        __prototype_type: "tm_entity"
        __prototype_uuid: "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"
        name: "box"
        components__instantiated: [
          {
            __type: "tm_transform_component"
            __uuid: "22222222-2222-2222-2222-222222222222"
            __prototype_type: "tm_transform_component"
            __prototype_uuid: "a2fed85d-b27e-81ad-31ed-843c8efc7d97"
            local_position_double: {
              __uuid: "33333333-3333-3333-3333-333333333333"
              __prototype_type: "tm_position_double"
              __prototype_uuid: "3ac3855d-a753-ed5e-7217-b0f82932d85c"
            }
          }
        ]
      }
      {
        __uuid: "44444444-4444-4444-4444-444444444444"
        __prototype_type: "tm_entity"
        __prototype_uuid: "fcd88464-f214-ea8f-14ea-828d51912c36"
        name: "sphere"
      }
    ]
    __asset_uuid: "99999999-9999-9999-9999-999999999999"
    """

    static func makeTempBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-tree-edit-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try world.write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func duplicateRemintsOnlyUUIDsAndKeepsPrototypeLinks() throws {
        let root = try #require(try TM.parse(Self.world).objectValue)
        let box = try #require(root["children"]?.arrayValue?.first?.objectValue)
        var minted = [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "cccccccc-cccc-cccc-cccc-cccccccccccc",
        ]

        let duplicate = RCP3EntityTreeWriteBack.duplicated(box) {
            minted.removeFirst()
        }

        #expect(duplicate.uuid == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(duplicate.prototypeType == "tm_entity")
        #expect(duplicate.prototypeUUID == "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0")
        #expect(duplicate.name == "box Copy")

        let component = try #require(duplicate["components__instantiated"]?.arrayValue?.first?.objectValue)
        #expect(component.uuid == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        #expect(component.prototypeUUID == "a2fed85d-b27e-81ad-31ed-843c8efc7d97")

        let position = try #require(component["local_position_double"]?.objectValue)
        #expect(position.uuid == "cccccccc-cccc-cccc-cccc-cccccccccccc")
        #expect(position.prototypeUUID == "3ac3855d-a753-ed5e-7217-b0f82932d85c")
        #expect(position.members.map(\.key) == ["__uuid", "__prototype_type", "__prototype_uuid"])
    }

    @Test func duplicateRewritesInternalUUIDReferences() throws {
        let text = """
        __uuid: "entity-old"
        name: "scripted"
        components: [
          {
            __uuid: "component-old"
            source: {
              __uuid: "graph-old"
              graph: {
                __uuid: "inner-graph-old"
                nodes: [
                  { __uuid: "node-a" }
                  { __uuid: "node-b" }
                ]
                connections: [
                  { __uuid: "connection-old" from_node: "node-a" to_node: "node-b" }
                ]
              }
            }
          }
        ]
        """
        let entity = try #require(try TM.parse(text).objectValue)
        var minted = [
            "entity-new",
            "component-new",
            "graph-new",
            "inner-graph-new",
            "node-a-new",
            "node-b-new",
            "connection-new",
        ]

        let duplicate = RCP3EntityTreeWriteBack.duplicated(entity) {
            minted.removeFirst()
        }
        let component = try #require(duplicate["components"]?.arrayValue?.first?.objectValue)
        let source = try #require(component["source"]?.objectValue)
        let graph = try #require(source["graph"]?.objectValue)
        let connection = try #require(graph["connections"]?.arrayValue?.first?.objectValue)

        #expect(duplicate.uuid == "entity-new")
        #expect(component.uuid == "component-new")
        #expect(source.uuid == "graph-new")
        #expect(graph.uuid == "inner-graph-new")
        #expect(connection.uuid == "connection-new")
        #expect(connection["from_node"]?.stringValue == "node-a-new")
        #expect(connection["to_node"]?.stringValue == "node-b-new")
    }

    @Test func editorDuplicatesEntityBesideOriginalAndPersists() throws {
        let dir = try Self.makeTempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        var editor = try RCP3Editor.open(dir)
        let duplicated = editor.duplicateEntity(id: "11111111-1111-1111-1111-111111111111")
        let duplicateID = try #require(duplicated)
        #expect(editor.hasUnsavedChanges)
        #expect(editor.entity.children.map(\.name) == ["box", "box Copy", "sphere"])
        #expect(editor.entity.children[1].id == duplicateID)
        #expect(editor.entity.children[1].prototypeUUID == editor.entity.children[0].prototypeUUID)
        #expect(editor.entity.children[1].uuid != editor.entity.children[0].uuid)

        try editor.save()
        let reopened = try RCP3Editor.open(dir)
        #expect(reopened.entity.children.map(\.name) == ["box", "box Copy", "sphere"])
        #expect(reopened.entity.children[1].id == duplicateID)
        #expect(reopened.entity.children[1].componentTypes == ["tm_transform_component"])
    }

    @Test func editorDeletesEntityAndPreservesSiblings() throws {
        let dir = try Self.makeTempBundle()
        defer { try? FileManager.default.removeItem(at: dir) }

        var editor = try RCP3Editor.open(dir)
        let deleted = editor.deleteEntity(id: "11111111-1111-1111-1111-111111111111")
        #expect(deleted)
        #expect(editor.entity.children.map(\.name) == ["sphere"])
        #expect(editor.entity.children.first?.uuid == "44444444-4444-4444-4444-444444444444")

        try editor.save()
        let reopened = try RCP3Editor.open(dir)
        #expect(reopened.entity.children.map(\.name) == ["sphere"])
        #expect(reopened.root["__asset_uuid"]?.stringValue == "99999999-9999-9999-9999-999999999999")
    }

    @Test func rootCannotBeDuplicatedOrDeleted() throws {
        var editor = try RCP3Editor.open(Self.makeTempBundle())
        defer { try? FileManager.default.removeItem(at: editor.bundle.url) }

        let duplicated = editor.duplicateEntity(id: editor.entity.id)
        let deleted = editor.deleteEntity(id: editor.entity.id)
        #expect(duplicated == nil)
        #expect(!deleted)
        #expect(!editor.hasUnsavedChanges)
    }
}
