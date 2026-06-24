# Captures needed — script-graph pin literal value encodings

Goal: pin the on-disk shape of each **pin-literal value kind** (the inner
`data: { … }` object of a `tm_graph` `data[]` entry) so we can model it in
``TMGraphValue`` and round-trip it faithfully. Clean-room: we implement only from
these **observed saved files**, never from guesses.

See the value-format table in [`CleanRoom-Spec.md`](./CleanRoom-Spec.md#pin-literal-value-encodings-datadata)
— each capture fills one ⬜ row.

## How to make each capture (one file, one graph, one value)

1. In Reality Composer Pro, **new project** (or duplicate the `Empty` baseline).
2. Add **one** script graph with the **minimal** wiring needed to expose the target
   input: an event node (e.g. *On Update*) → one node that has the target-typed
   input pin.
3. Set **that one input to a constant** (do **not** wire it), leave everything else
   default. One literal per file — that's what isolates the `data[]` entry.
4. **Save**, then from the bundle's `*.tm_script_graph` (or the entity's
   `re_scripting_component → source.graph`) copy the matching `data[]` entry —
   specifically its inner `data: { … }` object.
5. Drop the file in `references/<name>.realitycomposerpro/` (captures live outside
   the OSS repo) **or** just paste the `data[]` entry into the relevant row.

The entry always looks like this; only the inner `data: { … }` differs per kind:

```
{ __uuid: "…"  to_node: "…"  to_connector_hash: "…"  data: { … ← THIS } }
```

## The list (8 captures)

| # | File name | Set this input to a constant | Value to set | What it pins |
|--|--|--|--|--|
| 1 | `lit-bool.realitycomposerpro` | any node with a **Bool** input (e.g. a Branch/If *condition*, or *Set Entity Enabled* flag) | `true` | boolean encoding |
| 2 | `lit-string.realitycomposerpro` | any node with a **String** input (e.g. *Find Entity* `name`) | `"hello"` | string encoding |
| 3 | `lit-int.realitycomposerpro` | any node with an **Integer** input (e.g. a loop count / index) | `42` | does int differ from `{ value: N }` double? |
| 4 | `lit-enum.realitycomposerpro` | any node with an **enum dropdown** (e.g. an operator/axis/phase selector) | a **non-default** case | `script_graph_enum` / `script_graph_enum_associated_value` members |
| 5 | `lit-vector3.realitycomposerpro` | a node with a **Vector3** input set directly (not via Make Vector) | `(1, 2, 3)` | whole-vector literal shape |
| 6 | `lit-color.realitycomposerpro` | a node/component with a **Color** input | any non-default color | color encoding |
| 7 | `lit-entityref.realitycomposerpro` | a pin that takes an **entity reference** (e.g. a *target entity* input) | another scene entity | entity-reference encoding |
| 8 | `lit-assetref.realitycomposerpro` | a pin that takes an **asset** (audio clip / animation / material) | any asset | asset-reference encoding |

Notes:
- Already observed (no capture needed): **number** `{ value: <number> }`, **variable
  ref** `{ __type: "tm_graph_variable_ref", name, ref }`, **component_type**
  `{ type: "<murmur64a hex>" }`.
- If a kind turns out to reuse `{ value: … }` (e.g. bool as a `value` boolean, int as
  a `value` number), that's a valid finding — just note it.
- Smallest acceptable batch to unblock real authoring: **#1 (bool)** and **#2
  (string)**. #4 (enum) is the next most valuable. #5–#8 can follow.

When a capture lands: fill its row in the spec's value-format table, then the
implementation is one `TMGraphValue` case + parser branch + write-back writer +
inspector affordance.
