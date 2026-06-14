# Reality Composer Pro 3 — Clean-Room Behavioral Spec

The **only** sanctioned input for implementing Deconstructed 3. Records *observed*
behavior and on-disk format facts — black-box findings from inspecting real RCP 3
projects and the running app. No decompilation; no reference to internal research
or commercial products.

> Status: **v1.** Established from controlled captures in `../../references/`:
> the sealed RCP 2 `Base` re-saved through RCP 3.0, and a fresh `Empty` with one box.
> RCP 3 app version 3.0 (build 75.0.14.500.1), macOS 27.

## Headline — RCP 3 replaced the document format

Re-saving the RCP 2 `Base` through RCP 3.0 showed:

- The RCP 2 layout (`Package.realitycomposerpro/…`, `Sources/**/Scene.usda`,
  `Package.swift`) is left **byte-identical** — untouched.
- RCP 3 adds a **new sibling bundle `<ProjectName>.realitycomposerpro/`**.
- A project created fresh in RCP 3 (`Empty`) contains **only** the new bundle —
  no `Sources/`, no `Scene.usda`, no `Package.swift`.

**The native RCP 3 document is `<Name>.realitycomposerpro/`, a text object-database.
USD is no longer the document format — it appears only as an import lane**
(`Scene.import/`, `settings.tm_usd` in the migrated `Base`). Migration is
**additive**: opening a legacy project writes the new bundle alongside the old
files and records a `__migration_index.tm_meta`. Deconstructed 3 treats the old
layout as read-only legacy and authors the new bundle.

## Bundle anatomy — `<Name>.realitycomposerpro/`

| Path | Role (observed) |
|--|--|
| `project.rcp` | 0-byte sentinel marking the bundle as an RCP project. |
| `__type_index.tm_meta` | **Self-describing schema**: 926 type definitions, each `name` + `properties[]` (`name`, `type`, `type_hash`, `default`). The format documents its own types. |
| `__project_settings.tm_project_settings` | Typed settings tree (e.g. `tm_cloth_project_settings`: simulation gravity/wind). |
| `__migration_index.tm_meta` | Present after migrating a legacy project. |
| `world.tm_entity` | Scene root entity (fresh projects). |
| `Scene.import/` | Compiled scene from a USD import (migrated projects): `Scene.tm_entity`, `geometry/*.tm_geometry` + `*.tm_buffers`, `materials/*.tm_material`, `meshes/*.tm_mesh_resource`, `settings.tm_usd`. |
| `core.lib/` | Built-in asset library present in every project: geometry prototypes (`box/plane/sphere.tm_entity`), default materials/physics material, environments + IBL textures (`.ktx`), shader/compute/creation graphs, data transforms, visual-cue icons (`.png`). |
| `Custom Components/` | Project custom components. |

Binary payload only in `*.tm_buffers/<uuid>.<hash>` (geometry buffers, KTX/PNG
textures; `file(1)` mis-identifies them). Everything structural is text.

## Serialization grammar (text)

UTF-8, tab-indented. A value is a quoted string, a number (stored as a double,
e.g. `-9.8100004196166992`), a nested object `{ … }`, or an array `[ … ]`.
Reserved keys use a `__` prefix:

| Key | Meaning |
|--|--|
| `__type` | Object's type name (must resolve in `__type_index.tm_meta`). |
| `__uuid` | Stable object identity. |
| `__prototype_type` / `__prototype_uuid` | Inheritance — this object derives from a prototype object. |
| `__asset_uuid` | Asset identity on an entity. |
| `components__instantiated` | Components inherited from a prototype (vs. `components`, authored directly). |

## Entity–component–prototype model

The scene is an **entity-component graph with prototype inheritance** (not USD
prims/attributes).

- **Entity** (`tm_entity`): `name`, `components: [ … ]`, `children: [ … ]`,
  `child_sort_values: [ … ]` (explicit child ordering), `__asset_uuid`.
- **Component** (e.g. `tm_transform_component`): typed object whose properties are
  themselves UUID'd sub-objects (`local_position_double`, `local_rotation`,
  `local_scale`).
- **Placing a primitive = instancing a `core.lib` prototype.** Observed: adding a
  box created a child entity with `__prototype_uuid` = the
  `core.lib/geometry/box.tm_entity` UUID (`05fe482f-…`, confirmed identical),
  `name: "box"`, and `components__instantiated` whose transform prototypes the
  library transform. Overrides live on the instance; unchanged values inherit.

Implication: **`core.lib` must be resolvable to load a scene** (prototypes are
referenced by UUID across files).

Canonical "one box in an empty scene" (`world.tm_entity`):

```
__type: "tm_entity"
name: "world"
components: [ { __type: "tm_transform_component"  …local_position_double/_rotation/_scale } ]
children: [
  {
    __prototype_type: "tm_entity"
    __prototype_uuid: "05fe482f-…"          # → core.lib/geometry/box.tm_entity
    name: "box"
    components__instantiated: [ { __type: "tm_transform_component"  __prototype_uuid: "…"  … } ]
  }
]
child_sort_values: [ { child: "<box uuid>" } ]
```

## Type-system map (926 types)

Prefixes (inferred from naming): `tm_*` = object-database/engine layer; `re_*` /
`RE_*` = RealityKit-engine types. Grouped onto the hardest-first roadmap:

- **Script graph (no-code logic):** `re_scripting_component`,
  `re_scripting_graph_component_type`, `re_scripting_source_graph`,
  `re_scripting_source_script`,
  `re_scripting_node_library{,_node,_method,_event,_property,_type,_code,_module}`,
  `script_graph_enum{,_associated_value}`, `script_reload_settings`,
  `script_graph_test_component`.
- **Behavior trees & state machines:** `BehaviorTreeDefinition`,
  `BehaviorNodeDefinition`, `BTActionNodeDefinition`, `BehaviorConditionDefinition`,
  `TriggerConditionDefinition`, `TagConditionDefinition`, `StateMachineNodeDefinition`,
  `StateDefinition`, `StateTransitionDefinition`, typed params
  (`{Bool,Float,Int,Option,String,Rotation,Vector2/3/4}BehaviorParameterDefinition`).
- **Animation / timeline:** `tm_animation{,_clip,_channel,_curve,_curve_key,_state_machine,_simple_player_component,_library_component}`,
  `AnimGraphDefinition`, `AnimNodeDefinition`, `AnimationClipNodeDefinition`,
  `tm_asm_*` (animation state machine: blend/regular/random/empty states, events,
  motion mixer).
- **Materials:** `*.tm_material`, `*.tm_shadergraph`, `core.lib/compute_graphs`
  (`default`, `billboard`) + `creation_graphs` (`pbr`, `mesh_component`,
  `import-image`), `data_transforms` (Color/Normal/Mask/Cubemap/Default).
- **Components / spatial:** `tm_transform_component`,
  `tm_attached_transform_component`, `custom_component`, anchoring
  `RE_ANCHORING_COMPONENT_{HAND,HEAD,PLANE,WORLD,OBJECT,STYLUS,CONTROLLER_TARGET_*,REFERENCE_OBJECT}`,
  physics `RE_PHYSICS_MATERIAL` / `RE_CHARACTER_COLLISION_FILTER`, audio
  `tm_audio_asset`, `tm_atmospheric_sky_component`.
- **Actions / tags (no-code blocks):** `ActionWrapperTagDefinition`,
  `"Play Audio_tag"`, `"Enable/Disable Entity_tag"`, `InternalTagDefinition`.

## Script graph — node graph format (observed)

From the `Random` capture: a box carrying a `re_scripting_component` plus a
sibling `Script Graph.tm_script_graph` asset. The component holds the no-code
logic; the asset holds the graph it instances.

**Wiring (entity → asset).** The entity's `re_scripting_component` has a
`source` whose `__prototype_uuid` is the graph asset's identity. The asset file
`<Name>.tm_script_graph` is a `re_scripting_source_graph` whose **root `__uuid`
equals that prototype uuid**. Resolution = scan the bundle dir for
`*.tm_script_graph` and match `__uuid`. (Captured: source
`__prototype_uuid 3d614328-…` → `Script Graph.tm_script_graph` root `__uuid`.)

**Asset shape.**
`re_scripting_source_graph { graph: tm_graph { nodes[], connections[], data[], interface }, validation_settings }`.

- **`nodes[]`** — `{ __uuid, type, label?, position{ x, y } }`. `type` is a plain
  member (e.g. `tm_gesture_event_drag`, `tm_set_component`), **not** `__type`.
  `label` is the author-given name (e.g. `"Set Transform"`).
- **`connections[]`** — `{ __uuid, from_node, to_node, from_connector_hash?, to_connector_hash? }`.
  `from_node`/`to_node` are **node `__uuid`s**. A connection with **no** connector
  hashes is an **exec / control-flow** wire; one **with** both hashes is a **data**
  wire (`fromPin → toPin`).
- **`data[]`** — `{ __uuid, to_node, to_connector_hash, data }`: a constant input
  bound to a node's pin; `data` is a typed object (`__type`).
- **Pins** are referenced by `connector_hash = MurmurHash64A(pin_name, seed 0,
  m = 0xc6a4a7935bd1e995)` — the **same hash** the type index uses for type names, and
  **uniform for both input (`to_connector_hash`) and output (`from_connector_hash`)
  pins**. Verified anchors: input `translation → 3e132861ebce0169`, input
  `component_type → 772749b3cbf24a8f`, output `sceneTranslation → 4f980d170a59f903`
  (`tm_transform_component → 8c878bd87b046f80`). Gesture-event nodes expose both a
  local-space pin and a scene-space variant (`translation` vs `sceneTranslation`,
  `location` vs `sceneLocation`); the captured graph wires the drag's *scene-space*
  delta. Hashes are stored as lowercase 16-digit hex; reverse via a known-name table,
  else show the hex.

Captured graph decodes as: *while dragging, set the box's `Transform` component
`translation` to the world-space drag delta* — one exec wire drag→set, one data wire
drag.`sceneTranslation` → set.`translation`, and a `component_type` literal on the set
node. The literal's `type` is `MurmurHash64A` of the **RealityKit component name**
(here `"Transform"` → `af53dc359e631774`), i.e. scripts target the runtime RealityKit
components (not the `.tm_*` `tm_transform_component` truth object). Gesture event nodes
expose local + scene-space pin variants (`translation`/`sceneTranslation`,
`location`/`sceneLocation`).

## Script-graph runtime — execution model (observed)

Observed by inspecting the shipped app bundle and the running editor (black-box):

- **The script graph executes as JavaScript.** The visual `tm_graph` is the
  authoring form; at play/build it is compiled to a JS program and run in a
  JavaScript engine, with the entity and its components exposed as JS objects.
- **Host scaffolding.** Before the compiled program, the runtime loads two small
  JS helpers (shipped as plain resources): a CommonJS-style **module system**
  (`define(name, factory)` / `require(name)`, lazy + memoized) and a **`Sequence`
  collection mixin** (`[Symbol.iterator]`, `entries`, `values`, `forEach`,
  `filter`, `map`, `find`, `includes`, operating over a `keys` list). The node
  library is delivered as **modules** the compiled program `require`s; a
  component collection (e.g. an entity's components) is exposed as an **iterable
  Sequence**.
- **Events drive it.** Gesture events (drag, tap) are dispatched to entities and
  invoke the handlers the program registered (matching the `tm_gesture_event_*`
  nodes).
- **Node palette.** The editor ships a catalog of ~**380 node types** spanning
  gesture/animation/audio/collision **events**, **component** get/set, **arrays**,
  **logic/math**, **destructure** (`break_*`) of composite types
  (vector/quaternion/matrix/color/…), **variables**, **delays**, and cloning.
  Each node carries a label, category, and description; nodes are marked
  `supported` / `experimental` / `deprecated`.
- **Script context API.** A running script's `this` (its scripting component) exposes a
  **fixed** set of members: properties `entity`, `scene`, `input`, `hostTime`,
  `osVersion`, and platform flags (`isVisionOS`/`isMacOS`/`isIOS`/`isTVOS`/
  `isSimulator`); methods `on`/`off`/`send` (event subscribe/unsubscribe/dispatch),
  `getRemoteValue`/`setRemoteValue` (synced variables), and timers `setInterval`/
  `setTimeout`/`clearInterval`/`clearTimeout`/`isTimerFinished`. The entity's specific
  components (`Transform`, …) are exposed on top, named by the type schema.
- **Implication for Deconstructed 3 (path 2).** A faithful runtime is a **public
  JavaScriptCore** context that (1) installs an equivalent module system +
  iterable-collection mixin, (2) exposes the entity/components as JS objects
  (property names from the type schema), (3) loads node-behavior modules, (4)
  runs the compiled graph program, and (5) dispatches gesture events to it. Our
  implementations are written independently to this behavioral contract.

## Open questions / next captures

- [ ] Grammar edge cases: enums, asset references, and how text objects link to
      binary `*.tm_buffers/<uuid>.<hash>` payloads (the `<uuid>.<hash>` naming).
- [x] **Script graph** captured + decoded (see "Script graph" above). Still to do:
      a **timeline/animation** and a **material edit** — diffed against `Empty` to
      isolate each subsystem's authored objects.
- [ ] USD import path: how `settings.tm_usd` → `Scene.import/*.tm_entity` (round-trip).
- [ ] Does USDKit open/render the new bundle directly, or only legacy `Scene.usda`?
      (render-path decision for the app.)
- [ ] Is `core.lib` byte-identical across projects (a fixed shipped library we can
      treat as constant)?
