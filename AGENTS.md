# Deconstructed 3 — Agent Instructions

## What this is

An open-source (Apache-2.0) macOS app that reverse-engineers and reconstructs
**Reality Composer Pro 3**: open, display, edit, and round-trip the
`.realitycomposerpro` package format. Successor to Deconstructed (sealed at
`final-rcp2`, which targeted RCP 1–2 on macOS 26).

## Critical constraints

**macOS 27+ ONLY.** Non-negotiable — RCP 3 targets it and the canonical
`RealityKitScripting` runtime requires it.

- No iOS / iPadOS / visionOS / older macOS.
- No `#available` / `@available`, no multi-platform conditionals.
- Swift 6.2, strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Native Observation; do not use `WithPerceptionTracking`.

## Architecture

The Composable Architecture (TCA) + the Point-Free stack, same as Deconstructed.
Carry forward its disciplines:

- Feature modules in an SPM package; the app target wires scenes.
- **Runtime dependency-install pattern:** a `@Dependency` client whose live value
  needs framework linkage available only in the app target (e.g. the binary
  `RealityKitScripting` framework) defines a **throwing** stub in the feature target
  and is installed at startup via `prepareDependencies`. Prefer throwing stubs over
  no-op stubs so a missed install fails loudly, not silently.

## Runtime substrate — RealityKit

| Concern | Engine |
|--|--|
| Document model | `TMFormat` (`.tm_*` text object-database), parsed + written directly |
| Render / selection | RealityKit via StageView's `RealityKitStageView` (`entity.name == primPath`, post-process outline) |
| Editing / authoring | direct `TMFormat` round-trip — mutate the parsed model, save back |
| Script execution | `RealityKitScripting` (macOS 27) + JavaScriptCore |

The document is parsed and written as its native text grammar; there is no USD
authoring layer in the loop. Keep runtime clients behind a pure-Swift contract
boundary as Deconstructed did: DTOs in / DTOs out.

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

Early but well past scaffolding. The first milestone — open + display +
round-trip an RCP 3 `.realitycomposerpro` package — is met for the format surface
covered so far, and scene + script-graph editing are functional. Built from the
behavioral spec in [`Docs/CleanRoom-Spec.md`](./Docs/CleanRoom-Spec.md).
