# RCP3 Script Graph Certification

`rcp3-certify` runs Script Graph fixtures through an installed Reality Composer
Pro 3 and emits fail-closed, reproducible evidence. It is an external RCP3 check;
it does not treat local compilation or structural round trips as RCP3 parity.

## Prepare a certification root

```sh
cd Packages/Deconstructed3Kit
swift run rcp3-certify init /absolute/path/to/certification-root
```

The command creates the `test.json` configuration expected by RCP3. Put each
`.realitycomposerpro` test project directly in that root. A project must contain
RCP3's Script Graph test nodes; an ordinary runnable graph is reported as skipped,
not passed.

### Export integration-test smoke projects

RCP3's minimum observed integration-test graph is an execution connection from
`tm_begin_test` to `tm_finish_test`. The finish node carries `success = true` and
an empty `message` string. The test graph must be assigned through an entity's
Scripting Component; merely placing a Script Graph asset in the Project Browser
does not make it executable.

`rcp3-dump export-test-smoke` clones an existing, initialized RCP3 project rather
than attempting to synthesize RCP3's project-wide support files. The exporter
removes inherited Script Graph assets and the root Scripting Component from the
clone only; the template is never modified. Each exported project contains:

- the contract matrix case's exact canonical fixture as an unassigned asset;
- a separately assigned `tm_begin_test` → `tm_finish_test` smoke graph; and
- the case's digest-bound `certificationProjectName` as its directory name.

This smoke tier proves that RCP3 loads the exact serialized fixture and executes
the integration-test harness. It does not, by itself, prove the runtime semantics
of the unassigned subject node. Runtime-semantic certification needs a case-specific
assertion graph.

```sh
swift run rcp3-dump export-test-smoke \
  /absolute/path/to/Initialized.realitycomposerpro \
  /absolute/path/to/certification-root \
  tm_add_child
```

Use `all` instead of a requested node type to export every contract-matrix case.
The exporter refuses to overwrite an existing digest-bound project.

The first case-specific semantic exporter exercises Bool construction through an
RCP3 assertion and terminal test result:

```sh
swift run rcp3-dump export-test-semantic \
  /absolute/path/to/Initialized.realitycomposerpro \
  /absolute/path/to/semantic-certification-root \
  tm_make_bool
```

The observed minimal terminal test path is `Begin Test → Finish Test`. `Begin Test`
is an RCP3 harness source and presents the On Update-style event surface. `Finish
Test` accepts execution, Bool `success` (registration default `true`), and String
`message` (registration default empty), then emits the terminal test result. The
ordinary creator palette must not expose these harness-only nodes.

## Run RCP3

```sh
swift run rcp3-certify /absolute/path/to/certification-root \
  --output /absolute/path/to/rcp3-certification.json
```

Optional flags select another RCP3 application bundle or timeout:

```sh
swift run rcp3-certify /absolute/path/to/certification-root \
  --app /Applications/RealityComposerPro.app \
  --timeout 300
```

The command exits `0` only when a fresh report contains at least one successful
test, no failed/skipped/not-executed/unknown result, no validation error, and RCP3
prints its successful Script Graph integration completion. `failed` and
`inconclusive` evidence exit `1`; invalid arguments or setup failures exit `2`.

The evidence records the RCP3 version/build, deterministic runner arguments, SHA-256
input manifest, bounded output tails, outer process status, integration completion,
report hash, normalized result counts, individually attributable project/test results,
and the final outcome. RCP3 can exit `1`
because of errors explicitly reported outside the integration test, so the fresh
Script Graph report and integration completion are authoritative; the outer status
is preserved for diagnosis.

## Merge evidence into the contract matrix

```sh
swift run rcp3-dump contract-matrix /absolute/path/to/rcp3-certification.json \
  > /absolute/path/to/rcp3-contract-matrix.json
```

For a harness/load smoke fixture that does not exercise the canonical subject's
behavior, merge it explicitly as authoring-only evidence:

```sh
swift run rcp3-dump contract-matrix /absolute/path/to/rcp3-certification.json \
  --evidence-mode authoring-smoke \
  > /absolute/path/to/rcp3-contract-matrix.json
```

Use `--evidence-mode semantic-runtime` (the default) only when the RCP3 test
contains case-specific assertions over the canonical subject node.

Certification project names include the full semantic fixture digest. The merge
accepts a result only when that exact name matches the current matrix case, so an
older success cannot certify a changed graph. A successful semantic integration
case marks both RCP3 authoring and runtime evidence as passing. An executed semantic
assertion failure marks authoring as accepted but runtime as failed. Authoring-smoke
results never alter runtime evidence; syntax or validation failures still fail
authoring acceptance. Skipped or unrelated cases remain unrecorded.
