# Reality Composer Pro 3 — Clean-Room Behavioral Spec

The **only** sanctioned input for implementing Deconstructed 3. Records *observed*
behavior and on-disk format facts — black-box findings from inspecting real RCP 3
projects and the running app. No decompilation; no reference to internal research
or commercial products.

> Status: **stub.** To be filled by the RCP 3 `.realitycomposerpro` format-delta
> probe (a diff of an RCP 3 save against the sealed Deconstructed fixtures).

## Package layout (baseline — carried from Deconstructed, RCP 1–2)

```
Package.realitycomposerpro/          # the document bundle
├── ProjectData/main.json            # path → UUID index (loose; filesystem is source of truth)
├── WorkspaceData/
│   ├── Settings.rcprojectdata       # editor settings
│   ├── SceneMetadataList.json       # hierarchy state
│   └── <user>.rcuserdata            # per-user prefs
├── Library/
└── PluginData/
Sources/<Name>/<Name>.rkassets/Scene.usda   # USD scene (sibling to the bundle)
```

`main.json` is a loose index: stale, duplicate, and inconsistently-encoded entries
are expected. The **filesystem is the source of truth** for what exists.

## Open questions for the format-delta probe (RCP 3)

- [ ] Did the package layout change? (new dirs/files under `WorkspaceData/`, `PluginData/`?)
- [ ] **Script graph / no-code game logic** — new in RCP 3. Where is it serialized?
- [ ] **Timeline / animation processor** authoring — on-disk representation?
- [ ] **Material / MaterialX** changes vs. `UsdPreviewSurface`?
- [ ] USDKit scene I/O parity: does USDKit open/save these scenes round-trip-clean?

Fill each with confirmed observations (and the fixture that proves it) before
implementing the corresponding feature.
