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

Scaffolding. First milestone: **open + display + round-trip** an RCP 3
`.realitycomposerpro` package.

## License

Apache-2.0. See [LICENSE](./LICENSE).
