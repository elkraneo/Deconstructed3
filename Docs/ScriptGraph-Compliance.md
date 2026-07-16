# Script Graph compliance

Script Graph support has independent evidence tiers. “Present in the catalogue,”
“authorable,” “opens and round-trips in RCP,” and “executes correctly” are not
synonyms and must never be reported as one parity percentage.

The sole product baseline for this document is Reality Composer Pro 3. Script
Graph did not exist in the earlier product generation, so no earlier-product
comparison is meaningful or used here.

Run the deterministic reconciliation against the harvested artifacts:

```sh
cd Packages/Deconstructed3Kit
swift run rcp3-dump audit-compliance \
  ../../../../HopperHarvest/script-graph-parity-ledger.json \
  ../../../../HopperHarvest/generated/script-graph-certification-matrix.json
```

## Baseline audit (2026-07-16)

- Harvested catalogue: 382 normalized rows. Of the 362 `tm_*` metadata entries,
  344 are ordinary creator-visible candidates and 18 are retained as classified
  non-creator evidence. The source catalogue's two transcription collisions are
  normalized losslessly: Get Entity Parameter becomes `tm_get_entity_parameter`,
  and the numeric Collision Group row becomes
  `tm_make_collision_group_number` while preserving its raw catalogue ID.
- Live fixed/schema/typed-dynamic palette: 341 node types; every palette type has
  an authoring recipe. Together with the three settings-backed material nodes,
  the audit has 344 authorable creator types, with no catalogue/authoring
  disagreement.
- Settings-backed material authoring adds `tm_get_material_parameter`,
  `tm_set_material_parameter_v2`, and `tm_modify_any_material` outside the fixed
  palette.
- The generic typed-dynamic settings path now creates concrete initial interfaces
  for 18 public nodes across Array, String, validation, and custom-event families.
  These are structurally round-trip tested but remain RCP acceptance candidates,
  not individually RCP-certified nodes. Get/Set Entity Parameter are also authorable
  through their recovered dedicated `tm_entity_parameter_node_settings` record;
  they are deliberately not emitted as generic dynamic-connector settings.
- The 18 non-creator identifiers remain visible in the ledger instead of being
  silently dropped: three feature-flagged diagnostics, six unavailable catalogue
  entries, six validation-test operations, one deprecated validation no-op, one
  canonical-ID alias, and one proven non-node form. They are excluded only from
  creator parity accounting.

  The versioned set is: `tm_begin_test`, `tm_breakpoint`, `tm_finish_test`,
  `tm_if_breakpoint`, `tm_log`, `tm_make_anim_graph_parameter_type`,
  `tm_make_keyboard_key_code`, `tm_make_triangle_fill_mode`, `tm_math_ease`,
  `tm_math_easein`, `tm_math_easeinout`, `tm_math_easeout`, `tm_math_remap`,
  `tm_set_test_time_out`, `tm_test_assert`, `tm_test_assert_equal`,
  `tm_test_undefined`, and `tm_test_update`.
- `tm_clone` is now creator-authorable through its recovered typed-dynamic
  contract: one Entity `source` input, one mirrored Entity `source` output, and
  the fixed action connectors. This is source/structural evidence, not an RCP
  round-trip or runtime certification claim.
- Behavioral corpus: 18 scenarios (three functional demos plus 15 focused
  patterns) using 25 unique node types. A separate deterministic authoring corpus
  covers all 341 palette types. A disk-level gate adds the three settings-backed
  material nodes, writes all 344 creator-authorable graphs as real assets, reopens
  them, and compares nodes, settings, connection hashes, literals, and typed
  variable declarations.
- Canvas and agent insertion now share one node-fragment recipe interpreter.
  Component selectors, enum/default settings, dynamic/material/entity-parameter
  settings, typed variables, and deprecated-node replacements therefore follow
  the same serialization path as generated fixtures.
- The authoring agent can inspect the live unsaved graph and its setting choices;
  add/remove/connect/move nodes; edit labels, literals, variables, enum cases,
  component types, entity-parameter types, and dynamic connector types/names;
  validate/compile; and invoke the real Save, Preview, Play, and Stop host actions.
- Validation is coverage-aware. Structural identities/endpoints, variable
  references/types, and enum/dynamic/material/entity settings are checked, while
  unknown interfaces and untyped declarations remain explicit coverage gaps.
  The same report is available headlessly with
  `rcp3-dump validate <project.realitycomposerpro>`.
- RCP authoring certification: eleven representative mechanisms passed
  RCP open/save/reopen. These certify mechanisms, not every node using them.
- Runtime certification: zero matrix cases are currently marked `pass`.
- NodeLib: portable identity derivation passes; same-process ingestion and runtime
  remain uncertified.

The generated ledger imports the certification matrix and reports eleven
representative RCP authoring passes and zero runtime passes. Creator authorability
is therefore structurally closed with an empty source-harvest queue, while RCP
round-trip and runtime parity remain separate, incomplete evidence tiers.
