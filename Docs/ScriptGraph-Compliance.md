# Script Graph compliance

Script Graph support has independent evidence tiers. “Present in the catalogue,”
“authorable,” “opens and round-trips in RCP,” and “executes correctly” are not
synonyms and must never be reported as one parity percentage.

Run the deterministic reconciliation against the harvested artifacts:

```sh
cd Packages/Deconstructed3Kit
swift run rcp3-dump audit-compliance \
  ../../../../HopperHarvest/script-graph-parity-ledger.json \
  ../../../../HopperHarvest/generated/script-graph-certification-matrix.json
```

## Baseline audit (2026-07-12)

- Harvested catalogue: 382 rows, 360 unique public-candidate identifiers. The
  ledger contains duplicate rows for `tm_set_entity_parameter` and
  `tm_make_collision_group`.
- Live fixed/schema/typed-dynamic palette: 336 node types; every palette type has an authoring
  recipe.
- Settings-backed material authoring adds `tm_get_material_parameter`,
  `tm_set_material_parameter_v2`, and `tm_modify_any_material` outside the fixed
  palette.
- The generic typed-dynamic settings path now creates concrete initial interfaces
  for 18 public nodes across Array, String, validation, and custom-event families.
  These are structurally round-trip tested but remain RCP acceptance candidates,
  not individually RCP-certified nodes. Get/Set Entity Parameter are also authorable
  through their recovered dedicated `tm_entity_parameter_node_settings` record;
  they are deliberately not emitted as generic dynamic-connector settings.
- Another 23 unique public-candidate identifiers are intentionally deferred:
  two pending public schemas; three feature-flagged diagnostics; three nodes not
  recovered from `libtm`; six unregistered catalogue entries; six validation-test
  nodes; one deprecated validation no-op; one alias; and one proven non-node form.
- Behavioral corpus: 15 scenarios using 20 unique node types. Of the 336 palette
  types, 316 do not yet occur in a curated end-to-end behavioral scenario. A
  separate deterministic authoring corpus covers all 336 palette types.
- RCP authoring certification: ten representative built-in mechanisms passed
  RCP open/save/reopen. These certify mechanisms, not every node using them.
- Runtime certification: zero matrix cases are currently marked `pass`.
- NodeLib: portable identity derivation passes; same-process ingestion and runtime
  remain uncertified.

The generated ledger currently reports zero RCP round trips and zero runtime
verification for all entries, despite the ten representative RCP authoring passes
in the matrix. The audit command therefore consumes the matrix directly. The
ledger generator should eventually import that evidence and reject duplicate IDs,
live-palette disagreement, and unknown certification subjects.
