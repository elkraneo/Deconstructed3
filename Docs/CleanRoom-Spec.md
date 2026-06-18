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

## Script-graph node library — node definitions (observed)

Beyond the gesture/component/lifecycle nodes already captured, the editor presents a
library of pure **data-only** value nodes: each has a fixed, named set of input and
output pins and **no exec/self pins** (they compute a result from their inputs rather
than firing in the control-flow sequence). As above, every pin is referenced by
`connector_hash = MurmurHash64A(pinName)` (seed 0, `m = 0xc6a4a7935bd1e995`), uniform
for input (`to_connector_hash`) and output (`from_connector_hash`) pins. The pin names
below are the observed connector identifiers (the hashed values); a node's display
title is separate from its pin names.

The constant nodes have **no inputs** and a single named output; the rest list inputs →
outputs.

**Math — Comparison.**

| type | inputs | outputs |
| --- | --- | --- |
| `tm_math_greater` | `a`, `b` | `result` |
| `tm_math_greater_equal` | `a`, `b` | `result` |
| `tm_math_less` | `a`, `b` | `result` |
| `tm_math_less_equal` | `a`, `b` | `result` |
| `tm_math_within_range` | `val`, `min`, `max` | `result` |
| `tm_math_random` | `min`, `max` | `result` |

**Math — Rotation.**

| type | inputs | outputs |
| --- | --- | --- |
| `tm_math_quaternion_to_euler` | `quaternion` | `angles` |
| `tm_math_euler_to_quaternion` | `angles` | `quaternion` |
| `tm_make_rotation` | `angle`, `axis` | `new` |
| `tm_make_look_at_rotation` | `at`, `from`, `upVector` | `new` |
| `tm_math_deg_to_rad` | `degrees` | `result` |
| `tm_math_rad_to_deg` | `rad` | `result` |

Observed JS emission for the rotation nodes implemented in the canonical compiler:

| type | emitted expression |
| --- | --- |
| `tm_make_rotation` | `new Math3D.Quaternion(angle, axis)` |
| `tm_math_euler_to_quaternion` | `Math3D.eulerAnglesToQuaternion(angles)` |
| `tm_math_quaternion_to_euler` | `Math3D.quaternionToEulerAngles(quaternion)` |

`tm_make_rotation` uses default inputs `angle = 0` and
`axis = new Math3D.Vector3(0, 1, 0)` when those pins are not otherwise supplied.

**Math — Constant** (no inputs; single output, named uppercase).

| type | output |
| --- | --- |
| `tm_constant_pi` | `PI` |
| `tm_constant_e` | `E` |
| `tm_constant_ln2` | `LN2` |
| `tm_constant_ln10` | `LN10` |
| `tm_constant_log10e` | `LOG10E` |
| `tm_constant_log2e` | `LOG2E` |
| `tm_constant_sqrt2` | `SQRT2` |
| `tm_constant_sqrt1_2` | `SQRT1_2` |

**Make.**

| type | inputs | outputs |
| --- | --- | --- |
| `tm_make_vector2` | `x`, `y` | `vec2` |
| `tm_make_vector3` | `x`, `y`, `z` | `vec3` |
| `tm_make_vector4` | `x`, `y`, `z`, `w` | `vector` |
| `tm_make_vector4_with_vector3` | `xyz`, `w` | `vector` |
| `tm_make_matrix2x2` | `col0`, `col1` | `source` |
| `tm_make_matrix3x3` | `col0`, `col1`, `col2` | `source` |
| `tm_make_matrix4x4` | `col0`, `col1`, `col2`, `col3` | `source` |
| `tm_make_cgcolor` | `red`, `green`, `blue`, `alpha` | `source` |
| `tm_make_color` | `red`, `green`, `blue`, `alpha` | `color` |
| `tm_make_cgsize` | `width`, `height` | `size` |
| `tm_make_edge_insets` | `top`, `left`, `bottom`, `right` | `insets` |

**String.**

| type | inputs | outputs |
| --- | --- | --- |
| `tm_string_has_prefix` | `string`, `prefix` | `result` |
| `tm_string_has_suffix` | `string`, `suffix` | `result` |
| `tm_string_contains` | `string`, `substring` | `result` |
| `tm_string_length` | `string` | `length` |
| `tm_string_prefix` | `string`, `length` | `result` |
| `tm_string_suffix` | `string`, `length` | `result` |
| `tm_string_substring` | `string`, `index`, `length` | `result` |

**Control Flow.** The unnamed event connector is represented by the empty string
connector name. `tm_sequence` and `tm_switch` grow dynamic event outputs; the library
does not invent fixed case/output connector names for those dynamic outputs.

| type | inputs | outputs |
| --- | --- | --- |
| `tm_sequence` | `""` | dynamic event outputs |
| `tm_if` | `""`, `condition` | `always`, `true`, `false` |
| `tm_switch` | `""`, `condition`, `continuous`, `first`, `count` | dynamic case outputs plus final default output |
| `tm_loop` | `""`, `begin`, `end`, `step`, `inclusive` | `step`, `end`, `index` |
| `tm_delay` | `""`, `seconds`, `is unique` | `always`, `once`, `cancelID` |
| `tm_cancel_delay` | `""`, `cancelID` | `""` |
| `tm_do_once` | `""` | `always`, `once` |

Observed JS emission for the control-flow nodes implemented in the canonical compiler:

| type | emitted behavior |
| --- | --- |
| `tm_sequence` | Calls each connected output event in connector order. |
| `tm_if` | Emits `always` first when connected, then `if (condition) { true } else { false }`. |
| `tm_switch` | Emits `switch (condition)` with cases derived from `first` and connected dynamic outputs; the last connected output is the default. |
| `tm_loop` | Emits a direction-aware `for` loop from `begin` to `end` by `step`, using `inclusive` to choose inclusive/exclusive bounds, then emits `end`. |
| `tm_delay` | Defines a delay helper, uses `this.setTimeout(..., seconds * 1000)`, stores `cancelID`, emits `always` after scheduling, and emits `once` when the timer fires. |
| `tm_cancel_delay` | Emits `this.clearTimeout(cancelID)`. |
| `tm_do_once` | Emits `always`, then a per-node guard that emits `once` only once. |

**Entity.**

| type | inputs | outputs |
| --- | --- | --- |
| `tm_entity_set_relative_transform` | `""`, `entity`, `scale`, `orientation`, `position`, `matrix`, `relativeTo` | `""` |
| `tm_entity_look_at` | `""`, `entity`, `at`, `from`, `upVector`, `relativeTo`, `positiveZForward` | `""` |
| `tm_self` | — | `entity` |
| `tm_scene` | — | `scene` |

Observed JS emission for the entity nodes implemented in the canonical compiler:

| type | emitted behavior |
| --- | --- |
| `tm_entity_set_relative_transform` | If supplied, calls `entity.setRelativeScale(scale, relativeTo)`, `entity.setRelativeOrientation(orientation, relativeTo)`, `entity.setRelativePosition(position, relativeTo)`, and `entity.setRelativeTransformMatrix(matrix, relativeTo)`. |
| `tm_entity_look_at` | Emits `entity.look(at, from, upVector, relativeTo, positiveZForward)`. |
| `tm_self` | Emits `this.entity`. |
| `tm_scene` | Emits `this.entity.scene`. |

**Logic.** Each yields a single `result`. The inputs are **variadic**: the node
presents a sequential list `a`, `b`, `c`, … and the editor's "add more inputs (+)"
affordance grows it; the library seeds the first two (`a`, `b`) — the "+" affordance is
deferred.

| type | inputs | outputs |
| --- | --- | --- |
| `tm_and` | `a`, `b`, … | `result` |
| `tm_or` | `a`, `b`, … | `result` |

**Math — Arithmetic & trig.** Each yields a single `result`. The binary operators take
a **variadic** input list (`a`, `b`, `c`, …; the library seeds `a`, `b`, with "+"
deferred); the unary operators take a single `a`; a few take a named auxiliary input.

| type | inputs | outputs |
| --- | --- | --- |
| `tm_math_add` | `a`, `b`, … | `result` |
| `tm_math_subtract` | `a`, `b`, … | `result` |
| `tm_math_multiply` | `a`, `b`, … | `result` |
| `tm_math_divide` | `a`, `b`, … | `result` |
| `tm_math_mod` | `a`, `b`, … | `result` |
| `tm_math_min` | `a`, `b`, … | `result` |
| `tm_math_max` | `a`, `b`, … | `result` |
| `tm_math_dot` | `a`, `b`, … | `result` |
| `tm_math_cross` | `a`, `b`, … | `result` |
| `tm_math_reflect` | `a`, `b`, … | `result` |
| `tm_math_bitwise_and` | `a`, `b`, … | `result` |
| `tm_math_bitwise_or` | `a`, `b`, … | `result` |
| `tm_math_bitwise_xor` | `a`, `b`, … | `result` |
| `tm_math_sin` | `a` | `result` |
| `tm_math_cos` | `a` | `result` |
| `tm_math_tan` | `a` | `result` |
| `tm_math_asin` | `a` | `result` |
| `tm_math_acos` | `a` | `result` |
| `tm_math_atan` | `a` | `result` |
| `tm_math_sqrt` | `a` | `result` |
| `tm_math_log` | `a` | `result` |
| `tm_math_log2` | `a` | `result` |
| `tm_math_abs` | `a` | `result` |
| `tm_math_ceil` | `a` | `result` |
| `tm_math_floor` | `a` | `result` |
| `tm_math_round` | `a` | `result` |
| `tm_math_trunc` | `a` | `result` |
| `tm_math_length` | `a` | `result` |
| `tm_math_normal` | `a` | `result` |
| `tm_math_bitwise_not` | `a` | `result` |
| `tm_math_pow` | `a`, `exponent` | `result` |
| `tm_math_clamp` | `a`, `min`, `max` | `result` |
| `tm_math_multiply_by_scalar` | `a`, `number` | `result` |
| `tm_math_multiply_by_quaternion` | `a`, `quaternion` | `result` |
| `tm_math_multiply_by_matrix` | `a`, `matrix` | `result` |

**Math — Constant** (literal). One additional constant node carries its literal value
in node **settings** rather than on a pin: it has no inputs and a single `value` output.

| type | inputs | outputs |
| --- | --- | --- |
| `tm_constant` | — (value in settings) | `value` |

**Variables.** Get/Set/Clear a named graph variable. For the **local** variants the
referenced variable is a **settings** field (a future variable-reference UI), not a pin,
so only the `value` data pin and exec pins are declared here; the **remote** variants
take the referenced variable as an Entity input pin (`Variable`). Set/Clear are
control-flow actions (exec in + exec out); Get is data-only.

| type | inputs | outputs | exec |
| --- | --- | --- | --- |
| `tm_get_variable_node` | — | `value` | — |
| `tm_set_variable_node` | `value` | — | in + out |
| `tm_clear_variable_node` | — | — | in + out |
| `tm_get_remote_variable_node` | `Variable` | `value` | — |
| `tm_set_remote_variable_node` | `Variable`, `value` | — | in + out |
| `tm_clear_remote_variable_node` | `Variable` | — | in + out |

**Variable compilation model (observed).** A graph declares its variables once in a
**graph-level variable table** — each entry a `{ name, type, default }` (variables are
renameable). A Get/Set/Clear node holds only a **by-name reference** to one of these
(a `tm_graph_variable_ref` settings field); the reference resolves against the table by
the **lowercased** name. The `value` pin's type derives from the referenced variable's
declared type (an unresolved reference falls back to an "any" type id).

- **Local** variables compile to an **instance property on the script** named by a
  stable slot. The slot id is `MurmurHash64A(lowercase(variableName), seed 0)`; the
  read slot is `variable_<id>` and the write slot is `variable_<id>_store`. So *Get*
  reads `this.variable_<id>` and *Set* writes it. (RCP authors this as a class
  getter/setter pair plus a `set_<name>` change message; a simpler faithful emission is
  a single `this.variable_<id>` property read on Get and assigned on Set — behaviorally
  identical for in-script accumulators, which is all our examples need.)
- **Remote** variables compile to `this.getRemoteValue(...)` / `this.setRemoteValue(...)`
  over a per-entity storage bag, keyed by the variable, and consume the `Variable`
  Entity input pin. Clear gates on whether the key is present before clearing.

**On-disk serialization (confirmed from a captured graph).** A graph that uses
variables stores, inside its `graph` object:

- A **variable table** under `variables:` — one entry per declared variable, each
  `{ __uuid, name }` (a type/default presumably appears once set; a freshly-declared
  variable carries just `__uuid` + `name`).
- A **per-node reference** in the graph's `data:` array — one entry per variable node,
  shaped exactly like a pin data-literal: `{ __uuid, to_node: <variable-node uuid>,
  to_connector_hash: <murmur64a("name")>, data: { __type: "tm_graph_variable_ref",
  __uuid, ref: <variable __uuid>, name: <variable name> } }`. So the node's **`name`**
  input connector carries a `tm_graph_variable_ref` value that points at the table entry
  by `ref` (uuid) and denormalizes the `name`.

Round-trip therefore is: parse `variables:` into a table; for each `tm_graph_variable_ref`
data entry, attach its `name` to the node identified by `to_node`. Writing back emits the
`variables:` table plus one `tm_graph_variable_ref` data entry per variable node. The
compile slot remains `variable_<MurmurHash64A(lowercase(name))>`.

**Deferred — dynamic pins, pending a follow-up harvest.** A residual family still
presents a fully **dynamic** pin set the editor grows from configuration, beyond the
fixed seed transcribed above: `tm_to_string` and `tm_string_merge`. These are omitted
from the library until their dynamic interfaces are pinned down. The variadic logic /
arithmetic nodes above are seeded with their first inputs; their "+" grow affordance is
likewise a deferred follow-up.

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
  Globals available outside `this` include a `console` (`log`/`warn`), the module
  system, and the iterable-collection mixin.
- **Implication for Deconstructed 3 (path 2).** A faithful runtime is a **public
  JavaScriptCore** context that (1) installs an equivalent module system +
  iterable-collection mixin, (2) exposes the entity/components as JS objects
  (property names from the type schema), (3) loads node-behavior modules, (4)
  runs the compiled graph program, and (5) dispatches gesture events to it. Our
  implementations are written independently to this behavioral contract.

## The runtime is Apple's public package — `apple/RealityKitScripting` (MIT)

RCP 3's script-graph runtime is a **public, MIT-licensed Apple Swift package**:
`https://github.com/apple/RealityKitScripting` ("JavaScript bindings for RealityKit
with type-safe Swift interop", currently beta). An RCP 3 **Build/Export** emits a
normal Xcode app that depends on it; the compiled script is baked into the
`.reality` file and runs on this package's runtime. The runtime ships as a binary
`xcframework`; its `@Scriptable` macro + compiler plugin are open Swift source.

This documents the real API directly (no inference needed):

- **Entry points:** `try RKS.initialize()` (or `.initialize(with: RKS.Configuration(id:)
  .onInitialize { … })`); attach a script with
  `entity.components.set(ScriptingComponent(source: jsString))`; enable systems with
  `.scriptingSystem()` / `.realityScripting()` (the latter also enables gesture + input).
- **Script `this`** is the scripting component; lifecycle methods are **assigned on `this`**:
  `this.update = function(deltaTime) { … }`, `this.didAdd`, `this.didActivate`,
  `this.scriptChanged`, `this.willDeactivate`, `this.willRemove`.
- **Entity API is the RealityKit `Entity` directly:** `this.entity.position` /
  `.orientation` / `.scale` / `.name` (a position is a `Math3D` vector with
  `.x/.y/.z`, `.add()`, `.clone()`). *(This corrects an earlier guess of
  `entity.transform.translation`.)*
- **Modules via `require`:** built-ins `RealityKit`, `Math3D`, `Foundation`,
  `CoreGraphics`; custom types via `TypeSchema<T>("Name") { StoredProperty / …
  Constructor / InstanceFunc / … }`, `EnumSchema`, grouped in `Module("Name") { … }`.
- **Gesture (the `Random` graph, verbatim from the package docs):**
  ```js
  this.didAdd = function() {
    this.entity.setComponent(new RealityKit.InputTargetComponent());
    this.entity.generateCollisionShapes(true);
    let dragStart;
    this.entity.on(RealityKit.DragGestureEvent.name, (e) => {
      const event = e.event;
      dragStart ??= event.entity.position.clone();
      event.entity.position = Math3D.add(dragStart, event.sceneTranslation);
      if (event.phase.equals(RealityKit.DragGestureEvent.Phase.ended)) dragStart = undefined;
    });
  };
  ```
- **Path-2 options for Deconstructed 3:** (a) **depend on the public package** and run
  genuine RCP scripts on Apple's runtime (most honest); or (b) keep our own public-
  JavaScriptCore host for portability/injection. Either way the target API is public
  and documented. *(Depending on Apple's public OSS does not touch our internal
  clean-room rule.)*

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
