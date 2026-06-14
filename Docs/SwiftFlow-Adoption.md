# Adopting SwiftFlow for the script-graph node editor — and its parity ceiling

> **Status (2026-06): SwiftFlow has been removed.** The "Recommendation" below was
> taken: `RCP3GraphEditor` now renders on our **own SwiftUI `Canvas`** node editor
> (`ScriptGraphCanvas` / `ScriptGraphCanvasNodeView` / `ScriptGraphLayout`) with
> per-pin connection points — the parity the SwiftFlow canvas could not give us.
> The `swift-flow` package dependency, the SwiftFlow-importing bridge
> (`ScriptGraphFlowBridge`), and the SwiftFlow node view (`ScriptGraphNodeView`)
> are gone. The renderer-agnostic pin/payload derivation that *was* in the bridge
> moved verbatim into `ScriptGraphPinResolver` (no SwiftFlow import); the stable
> pin handle-ids (`exec.in` / `exec.out` / `in.<hex>` / `out.<hex>`) are unchanged.
> This document is kept as the record of why we adopted SwiftFlow and why we
> outgrew it.

Deconstructed 3's visual script-graph editor (`RCP3GraphEditor`) renders an
`RCP3ScriptGraph` on a [SwiftFlow](https://github.com/1amageek/swift-flow) canvas
(MIT). SwiftFlow gave us node dragging, pan/zoom, selection, and edge drawing for
free, and `@ViewBuilder` node content let us author RCP-styled nodes. The data
model (`RCP3ScriptGraph`), node library (`ScriptGraphNodeLibrary`), component
registry (`ComponentSpec`), and the bridge's pin/edge derivation are all
renderer-independent — only the *canvas* is SwiftFlow.

## The blocking limitation: one connection point per side, not per pin

SwiftFlow routes **every edge endpoint** to one of five fixed points per node —
`FlowStore.handlePoint(for:in:)` returns top / bottom / left / right / center based
solely on a handle's `HandlePosition`. There is **no per-pin connection point**:
all `.left` handles resolve to the node's left-middle, all `.right` to its
right-middle.

Consequence for RCP parity: RCP script-graph nodes expose **many pins per side**
(e.g. "On Drag" has 9 data outputs; "Set Transform" has Source / Component Type /
Translation / Rotation / Scale / Matrix inputs). On a SwiftFlow canvas every wire
into a side collapses onto the same point, so multiple connections **overlap into a
single visible line** and do not align with their named pin rows.

Workaround applied: exec (control-flow) pins are routed to `.top` so the exec
connection at least renders separately from the side data wires (and matches RCP's
top exec line). This fixes simple graphs (one data wire per side) but **not** the
general multi-pin case.

## Recommendation

For full parity (each wire connecting a distinct, row-aligned pin), the canvas
needs **per-pin connection points** — which SwiftFlow does not model. The path is
our **own SwiftUI `Canvas` node renderer**: lay out each pin as a row, place its
connection point at that row, and draw edges between row points. Everything else
(`RCP3ScriptGraph`, `ScriptGraphNodeLibrary`, `ComponentSpec`, the bridge's
pin/edge derivation, the value resolution) is reused unchanged — only the
SwiftFlow `FlowCanvas`/`FlowStore`/handle layer is replaced.

This is the "graduate to our own renderer when fidelity demands it" point noted
when SwiftFlow was first adopted. SwiftFlow remains a fine prototype and reference.
