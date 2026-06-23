import Foundation
import RCP3Document
import TMFormat
import Testing

@testable import DeconstructedFeature

/// Coverage for the pure pieces behind the entity outliner. Identity and the
/// selection highlight are owned by SwiftUI's `List(selection:)` (each row carries a
/// `.tag`), so the testable logic is: the row-tag codec (`OutlineSelectionID`), the
/// component round-trip through that tag (`EntityOutlinerComponent(id:)`), and the
/// component de-duplication that keeps one row per component type.
@Suite struct OutlinerRowTests {
    // MARK: Row-tag codec

    @Test func componentTagRoundTrips() {
        let tag = OutlineSelectionID.component(entityID: "abc-123", componentID: "tm_collision_component")
        let decoded = OutlineSelectionID.decode(tag)

        #expect(decoded?.entityID == "abc-123")
        #expect(decoded?.componentID == "tm_collision_component")
    }

    @Test func plainEntityTagDecodesToNil() {
        // An entity tag is a bare uuid (no `#`), so it must not decode as a component.
        #expect(OutlineSelectionID.decode("abc-123") == nil)
    }

    @Test func componentInitMapsKnownKinds() {
        #expect(EntityOutlinerComponent(id: "transform").kind == .transform)
        #expect(EntityOutlinerComponent(id: "model").kind == .model)
        #expect(EntityOutlinerComponent(id: "tm_collision_component").kind == .other("tm_collision_component"))
    }

    @Test func componentIDIsStableThroughTagAndBack() {
        // The id a row tags with must reconstruct the same component kind.
        for component in [
            EntityOutlinerComponent(kind: .transform),
            EntityOutlinerComponent(kind: .model),
            EntityOutlinerComponent(kind: .other("tm_physics_body_component")),
        ] {
            let tag = OutlineSelectionID.component(entityID: "e", componentID: component.id)
            let decoded = OutlineSelectionID.decode(tag)
            #expect(decoded.map { EntityOutlinerComponent(id: $0.componentID) } == component)
        }
    }

    // MARK: Component de-duplication

    @Test func outlinerComponentsDeduplicatesByID() {
        // A type present in BOTH `components` and `components__instantiated` must
        // surface once — two rows with one id would let a click highlight both.
        let entity = RCP3Entity(
            TMObject(members: [
                .init(key: "__uuid", value: .string("a")),
                .init(key: "name", value: .string("box")),
                .init(key: "components", value: .array([
                    component("tm_transform_component"),
                    component("tm_collision_component"),
                ])),
                .init(key: "components__instantiated", value: .array([
                    component("tm_collision_component"),
                ])),
            ])
        )

        let ids = entity.outlinerComponents.map(\.id)
        #expect(Set(ids).count == ids.count, "component rows must have unique ids")
        #expect(ids.filter { $0 == "tm_collision_component" }.count == 1)
    }

    private func component(_ type: String) -> TMValue {
        .object(TMObject(members: [.init(key: "__type", value: .string(type))]))
    }
}
