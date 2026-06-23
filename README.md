# Deconstructed 3

> [!NOTE]
> Work in progress. Successor to [Deconstructed](https://github.com/elkraneo/Deconstructed)
> (sealed at `final-rcp2`). Targets **Reality Composer Pro 3** on the macOS 27
> USDKit-native stack.

An open-source macOS application that reverse-engineers and reconstructs
**Reality Composer Pro 3** — opening, displaying, editing, and round-tripping the
`.realitycomposerpro` package format.

## Relationship to Deconstructed

Deconstructed (1–2) is sealed: it targets the pre–RCP 3 format on macOS 26, on the
`SwiftUsdShell` + OpenUSD runtime. Deconstructed 3 is a clean successor that tracks
RCP 3 on Apple's **USDKit** (macOS 27+). Same OSS posture (Apache-2.0), same
architecture stack (TCA + Point-Free), fresh runtime substrate.

## Runtime substrate — USDKit first

| Concern | Engine | Why |
|--|--|--|
| Render | USDKit + RealityKit (`USDStageComponent`) | In-scene entities per prim path; picking, post-process selection, grid/IBL all reach it. |
| Selection | USDKit + RealityKit | Pick by `entity.name == primPath`; outline via custom post-process. |
| Mutation / authoring | `SwiftUsdShell` (reconnected on demand) | USDKit's authoring layer is private (array marshalling, connection authoring); the Shell is the controllable authoring engine, kept behind the same pure-Swift contract boundary used in Deconstructed. |

USDKit is the base; the Shell returns only where authoring needs it.

## Platform

- **macOS 27+ only.** USDKit requires it; RCP 3 targets it. No back-compat, no `#available`.
- Swift 6.2, strict concurrency, MainActor-by-default.
- The Composable Architecture (TCA).

## Clean-room discipline

Deconstructed 3 is built from **observed behavior and file-format facts**, documented
in [`Docs/`](./Docs). It does not contain, quote, or derive from binary
decompilation, and it does not depend on or reference any commercial product. The
internal reverse-engineering research lives in a separate private vault and never
flows into this repository. See [`AGENTS.md`](./AGENTS.md).

## Status

Early but well past scaffolding. The first milestone — **open + display +
round-trip** an RCP 3 `.realitycomposerpro` bundle — is met for the format
surface covered so far, and scene + script-graph editing are functional. The
library (`Deconstructed3Kit`) is ~11.5k lines across eight modules with ~270
tests. Built from the behavioral spec in [`Docs/CleanRoom-Spec.md`](./Docs/CleanRoom-Spec.md).

### What works today

| Area | State |
|--|--|
| **`.tm_*` text object-database** | Parse + write the tab-indented grammar; faithful round-trip (`TMFormat`). |
| **Open + display** | Load an RCP 3 bundle, show the entity/component/prototype tree and a RealityKit viewport (via StageView's `RealityKitStageView`). |
| **Scene editing** | Transform edit, entity duplicate / delete, primitive insertion — all with faithful save back to the bundle. |
| **Script graphs (visual)** | A node editor on a custom SwiftUI `Canvas` with per-pin connection points; pin-literal and variable authoring; round-trip save of entity-attached and asset graphs. |
| **Script graphs (execution)** | Compile `tm_graph` → JavaScript and run it two ways: a JavaScriptCore host, and Apple's canonical `RealityKitScripting` runtime (macOS 27). Node coverage spans math / Math3D, comparison / logic / string / bitwise, control-flow, entity, and event nodes. |
| **Examples gallery** | Loadable, playable script-graph examples. |
| **`rcp3-dump`** | A CLI that opens a bundle and prints its scene tree. |

### Not yet

- Full coverage of the 926-type RCP 3 schema — only a working subset is authored.
- High-fidelity display of the USD **import lane** (`Scene.import/` geometry/materials).
- Authoring beyond the currently covered node / component set.

## License

Apache-2.0. See [LICENSE](./LICENSE).
