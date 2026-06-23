import Foundation
import RCP3Document
import TMFormat
import Testing

@testable import DeconstructedFeature

/// Coverage for the outliner's pre-flattened row model. The flat `[OutlinerRow]`
/// (one `ForEach`, unique stable ids) replaced a recursively-nested
/// `Group`/`ForEach` view whose ambiguous row identity made selecting one row
/// highlight several. These tests pin the two guarantees behind that fix:
/// every emitted row id is unique, and a component type that appears in both
/// `components` and `components__instantiated` collapses to a single row.
@Suite struct OutlinerRowTests {
    // MARK: Fixtures

    private func component(_ type: String) -> TMValue {
        .object(TMObject(members: [.init(key: "__type", value: .string(type))]))
    }

    /// A `tm_entity` object with a transform component (always) plus optional extra
    /// authored / instantiated component types, an optional geometry-prototype link
    /// (so it reads as a Model), and children.
    private func entity(
        uuid: String,
        name: String,
        geometry: Bool = false,
        components: [String] = [],
        instantiated: [String] = [],
        children: [TMValue] = []
    ) -> TMObject {
        var members: [TMObject.Member] = [.init(key: "__uuid", value: .string(uuid))]
        if geometry {
            members.append(.init(key: "__prototype_type", value: .string("tm_entity")))
            members.append(.init(key: "__prototype_uuid", value: .string("proto-\(uuid)")))
        }
        members.append(.init(key: "name", value: .string(name)))
        members.append(.init(
            key: "components",
            value: .array([component("tm_transform_component")] + components.map(component))
        ))
        if !instantiated.isEmpty {
            members.append(.init(key: "components__instantiated", value: .array(instantiated.map(component))))
        }
        if !children.isEmpty {
            members.append(.init(key: "children", value: .array(children)))
        }
        return TMObject(members: members)
    }

    // MARK: Tests

    @Test func flattenProducesUniqueRowIDs() {
        // `box` carries the SAME component type in both authored and instantiated
        // arrays — the case that used to emit two rows sharing a selection key.
        let boxA = entity(
            uuid: "a", name: "box", geometry: true,
            components: ["tm_collision_component"], instantiated: ["tm_collision_component"]
        )
        let boxB = entity(uuid: "b", name: "box (1)", geometry: true)
        let world = entity(uuid: "w0", name: "world", children: [.object(boxA), .object(boxB)])

        let rows = OutlinerRow.flatten(root: RCP3Entity(world), expanded: ["w0", "a", "b"])
        let ids = rows.map(\.id)

        #expect(Set(ids).count == ids.count, "every outliner row id must be unique")
    }

    @Test func duplicateComponentTypeCollapsesToOneRow() {
        let box = entity(
            uuid: "a", name: "box", geometry: true,
            components: ["tm_collision_component"], instantiated: ["tm_collision_component"]
        )
        let world = entity(uuid: "w0", name: "world", children: [.object(box)])

        let rows = OutlinerRow.flatten(root: RCP3Entity(world), expanded: ["w0", "a"])
        let collisionRows = rows.filter { row in
            guard case let .component(component) = row.kind, row.entity.id == "a" else { return false }
            return component.id == "tm_collision_component"
        }

        #expect(collisionRows.count == 1, "a type in both component arrays must yield one row")
    }

    @Test func collapsedEntityHidesComponentsAndChildren() {
        let child = entity(uuid: "c", name: "box", geometry: true)
        let world = entity(uuid: "w0", name: "world", children: [.object(child)])

        // Nothing expanded: only the root entity row, flagged as having children.
        let rows = OutlinerRow.flatten(root: RCP3Entity(world), expanded: [])

        #expect(rows.count == 1)
        #expect(rows.first?.id == "/w0")
        #expect(rows.first?.hasChildren == true)
        #expect(rows.first?.isExpanded == false)
    }
}
