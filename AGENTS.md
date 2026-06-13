# Deconstructed 3 — Agent Instructions

## What this is

An open-source (Apache-2.0) macOS app that reverse-engineers and reconstructs
**Reality Composer Pro 3**: open, display, edit, and round-trip the
`.realitycomposerpro` package format. Successor to Deconstructed (sealed at
`final-rcp2`, which targeted RCP 1–2 on macOS 26).

## Critical constraints

**macOS 27+ ONLY.** Non-negotiable — USDKit requires it and RCP 3 targets it.

- No iOS / iPadOS / visionOS / older macOS.
- No `#available` / `@available`, no multi-platform conditionals.
- Swift 6.2, strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Native Observation; do not use `WithPerceptionTracking`.

## Architecture

The Composable Architecture (TCA) + the Point-Free stack, same as Deconstructed.
Carry forward its disciplines:

- Feature modules in an SPM package; the app target wires scenes.
- **Shell-runtime dependency-install pattern:** a `@Dependency` client whose live
  value needs USD/Cxx defines a **throwing** stub in the feature target and is
  installed at startup via `prepareDependencies`. Prefer throwing stubs over no-op
  stubs so a missed install fails loudly, not silently.

## Runtime substrate — USDKit first

| Concern | Engine |
|--|--|
| Render | USDKit + RealityKit (`USDStageComponent`) |
| Selection | USDKit + RealityKit (`entity.name == primPath`, post-process outline) |
| Mutation / authoring | `SwiftUsdShell`, reconnected on demand |

USDKit is the base. The Shell returns **only** at the authoring/mutation seam,
because USDKit's authoring layer (array marshalling, connection authoring) is
private. When it returns, keep it behind a pure-Swift contract boundary exactly as
Deconstructed did: DTOs in / DTOs out, no C++ types cross the boundary.

## Clean-room firewall — read before writing any code

This repository is published OSS. It must stay defensible and leak-free:

1. **Build only from `Docs/`** — the observed behavior/format specs (black-box
   findings from real RCP 3 projects and the running app).
2. **Never** paste, quote, transcribe, or derive code from binary decompilation.
3. **Never** reference, name, or depend on internal research or commercial products
   in code, comments, commit messages, or docs here. Forbidden in this repo:
   the private research vault (`usd-rcp` / `vaults`), `Drydock`, `OpenUSDKit`,
   `Gantry`, `Hull`, `Preflight`.
4. The internal reverse-engineering research lives in a separate private vault and
   is consulted only to decide *what to investigate* — it never flows into this repo.

If a fact isn't yet in `Docs/`, add it there as an observed fact first, then implement.

## Document format

`.realitycomposerpro` is a package bundle. See [`Docs/CleanRoom-Spec.md`](./Docs/CleanRoom-Spec.md)
for the known structure (carried from the sealed Deconstructed baseline) and the
open questions for RCP 3.

## Status

Scaffolding. First milestone: open + display + round-trip an RCP 3
`.realitycomposerpro` package.
