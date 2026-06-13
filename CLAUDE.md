# Deconstructed 3

Open-source (Apache-2.0) macOS 27+ app reconstructing **Reality Composer Pro 3**:
open / display / edit / round-trip the `.realitycomposerpro` format. Successor to
Deconstructed (sealed `final-rcp2`).

- **macOS 27+ only.** USDKit-native. No `#available`, no back-compat. Swift 6.2, TCA.
- **Runtime:** USDKit + RealityKit for render & selection; `SwiftUsdShell`
  reconnected only for mutation/authoring (USDKit's authoring layer is private).
- **Clean-room:** build only from observed-behavior specs in `Docs/`; never from
  decompilation; never reference the private research vault or any commercial
  product. Full rules in `AGENTS.md`.

First milestone: open + display + round-trip an RCP 3 `.realitycomposerpro` package.
