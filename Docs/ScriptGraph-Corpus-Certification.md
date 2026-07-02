# Script Graph corpus certification

The Examples gallery is the behavioral certification corpus for Script Graph
support. A node appearing in the palette or compiler is not by itself evidence of
RCP3 parity. A scenario is useful evidence only when its complete interaction path
authors, compiles, serializes, reopens, and executes correctly.

## Certification levels

- **Automated:** graph invariants, editor interfaces, canonical compilation, and
  host-runtime tests pass.
- **Manual pending:** automated checks pass, but the graph has not completed the
  RCP3 procedure below.
- **RCP3 certified:** the materialized graph completed the procedure against a
  recorded RCP3 build and date.

Certification applies to a specific scenario and RCP3 build. It does not certify
every possible composition of the nodes involved.

## Manual RCP3 procedure

For each example:

1. Create a disposable copy of a `.realitycomposerpro` project.
2. Materialize the complete corpus headlessly when testing a batch:

   ```sh
   cd Packages/Deconstructed3Kit
   swift run rcp3-dump export-corpus /path/to/Disposable.realitycomposerpro
   ```

   The command creates one real `.tm_script_graph` asset per
   `ScriptGraphExamples.all` entry using the same asset writer as the app.

3. Alternatively, open the disposable project in Deconstructed3.
4. In Project Browser, choose **+ → Samples → _Example Name_**.
5. Save, close, and reopen the project in Deconstructed3. Confirm the graph is
   structurally intact.
6. Open the same project and graph in Reality Composer Pro 3.
7. Confirm all nodes, labels, pins, literals, and flow/data wires load without
   repair, substitution, or warnings.
8. Attach the graph to the intended entity through a Scripting component when the
   sample is not already attached.
9. Run Preview and perform the example's `manualSteps`.
10. Confirm the visible result matches `expectedOutcome`.
11. Save in RCP3, then reopen in Deconstructed3 and confirm nodes, wires, literals,
   variables, and labels still match.
12. Record the RCP3 build and test date in the example's certification status.

Use project editing for certification and ambiguous runtime behavior, not for
discovering hundreds of individual node interfaces. Registration metadata and
source analysis remain the scalable inventory mechanism.

## External pattern policy

Unity and Unreal samples are sources of interaction patterns, not serialization or
runtime specifications. Rebuild patterns from public descriptions using RCP3 node
semantics and original test assets. Do not copy proprietary graphs or content.

Useful pattern families include:

- trigger opens door;
- button toggles light;
- pickup and counter;
- collision changes material;
- delayed action and cancellation;
- one-shot tutorial or pickup trigger;
- animation and audio playback;
- entity spawning and lifecycle;
- custom-event communication;
- arrays and inventory;
- look-at/follow behavior;
- variable-and-switch state machines.

Apple RCP3 samples are the highest-value scenario references because they represent
the intended runtime and authoring workflow. Decompose large samples into small
recipes first, then retain one end-to-end project as a stress test.

## Current corpus

The corpus is declared by `ScriptGraphExamples.all`. Automated tests enforce:

- stable and unique example identities;
- compilation without unsupported wired paths;
- complete certification metadata;
- explicit observable outcomes and manual steps;
- a declared editor `NodeSpec` for every used node type;
- coverage for newly added control-flow and constructor behavior;
- materialize → reopen structural equality for every example: node identities,
  types, labels, positions, variable references, wire connectivity including
  connector hashes, authored data-literal values, and the variable table.
