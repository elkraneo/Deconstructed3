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
`inconclusive` evidence exit `1`; invalid arguments or preflight failures exit `2`.

The evidence records the RCP3 version/build, deterministic runner arguments, SHA-256
input manifest, bounded output tails, outer process status, integration completion,
report hash, normalized result counts, and the final outcome. RCP3 can exit `1`
because of errors explicitly reported outside the integration test, so the fresh
Script Graph report and integration completion are authoritative; the outer status
is preserved for diagnosis.
