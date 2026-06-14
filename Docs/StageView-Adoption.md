# Adopting StageView's `RealityKitStageView` as the viewport

Deconstructed 3 renders RCP 3 `.tm_*` scenes by **reconstructing public RealityKit
entities** from the parsed object database — there is no USD in this path. To get a
production-grade viewport (orbit camera, grid, IBL, selection outline, correct
macOS picking) without re-implementing it, we adopt the **StageView** package's
`RealityKitStageView` and feed it our reconstructed entities.

We reuse StageView's *RealityKit render path*, not its *USD-import path*: we never
call `Entity(contentsOf:)`/`load`, we inject an externally-built hierarchy through
`RealityKitProvider.setModel(_:metersPerUnit:isZUp:)`.

This doc records (a) how we adopted it, (b) the friction we hit, and (c) concrete,
constructive improvement proposals for StageView. We do **not** modify the StageView
repo — these are proposals.

## Where the code lives

- `Packages/Deconstructed3Kit` product **`RCP3Viewport`**
  - `RCP3EntityBuilder` — `RCP3SceneNode` → RealityKit `Entity` + `SceneBounds` +
    uuid↔prim-path bridge map.
  - `RCP3ViewportView` — owns a `RealityKitProvider` + `StoreOf<StageViewFeature>`,
    injects entities, hosts `RealityKitStageView`, bridges selection both ways.
- App: `Deconstructed3/ContentView.swift` now uses `RCP3ViewportView`
  (the hand-rolled `SceneViewportView` was retired/deleted).

## (a) How we adopted it

### 1. Entity injection via `setModel`
`RCP3EntityBuilder.build(from:)` walks the `RCP3SceneNode` tree and emits a
`ModelEntity` (box/sphere/plane mesh + collision shape for picking) for primitive
nodes and a bare `Entity` for structural nodes, applying each node's resolved
`Transform(scale:rotation:translation:)`. `RCP3ViewportView` then calls:

```swift
provider.setModel(build.root, metersPerUnit: 1, isZUp: false)
provider.setExternalSceneBounds(build.bounds)
```

`setModel` sets `modelEntity`, builds the prim-path mapping, and the view's
`onChange(of: runtime.modelEntity)` mounts the entity under `ModelAnchor` and
auto-frames the camera.

### 2. UUID-as-identity (selection round-trip)
StageView keys selection on **"prim path" strings** that it reconstructs by walking
entity **names** (`buildPrimPathMapping` / `RealityKitProvider.refreshPrimPathMapping`).
To make those strings round-trip to *our* RCP 3 uuids:

- Every entity is named with its node `id` (the entity uuid):
  `entity.name = node.id`.
- We also set `USDPrimPathComponent(primPath:)` with the same slash-joined uuid
  chain the provider computes, so the identity we register matches the identity
  StageView stores.
- A node's prim path is therefore `/<worldUUID>/<boxUUID>`; its **leaf component is
  always the node uuid**.

Bridging:
- **Host → viewport:** `selection` (uuid) → look up full prim path in
  `primPathByNodeID` → `provider.setSelection(path)`.
- **Viewport → host:** a pick bumps `provider.selectionGeneration`; we read
  `provider.selectedPrimPath`, take its **last path component** as the uuid, and
  write the `selection` binding. (`RCP3EntityBuilder.nodeID(forPrimPath:)`.)
- A push/echo guard (compare current `provider.selectedPrimPath` before pushing;
  compare decoded uuid before writing the binding) prevents a feedback loop.

### 3. The anonymous-wrapper requirement
`RealityKitProvider` was written for `Entity(contentsOf:)`, whose result is an
**anonymous wrapper** whose *children* are the real prims. `refreshPrimPathMapping`
**skips the entity you hand to `setModel`** (treats it as the unnamed root) and only
walks its children. If we passed our `world` entity directly, the mapping would
produce `/box…` and **drop `world` entirely** — `world` would be unselectable and
the prim paths wouldn't match our registered ones.

Fix: `build(from:)` returns an **unnamed container entity** whose single child is
our scene root, mirroring the shape `Entity(contentsOf:)` produces. (This is the one
non-obvious step; it is covered by `providerMappingAgreesWithOurPrimPaths` test.)

### 4. Store wiring (`StageViewFeature`)
`RealityKitStageView` requires a `StoreOf<StageViewFeature>`. We instantiate a
private store and use it for three things:

- `setSceneBounds(_:)` — the view forwards `store.sceneBounds` to the provider on
  appear and on change, so authored bounds must live in the store too (we set both
  the store and call `provider.setExternalSceneBounds`).
- selection state mirror.
- **The pick gate.** `RealityKitStageView.shouldAcceptViewportPick` refuses all
  picks unless `store.modelURL != nil` **and** `store.activeLoadCommand == nil`
  **and** `runtime.isLoaded` **and** `runtime.modelEntity != nil`. Because we never
  issue a URL load, `modelURL` would stay nil and **clicking would silently do
  nothing**. We work around this by sending a **sentinel** `loadRequested` with a
  dummy `rcp3-viewport://injected` URL and then immediately completing the command
  (`loadCommandCompleted`) so `activeLoadCommand` returns to nil while `modelURL`
  stays set. We never load from that URL; the provider owns the entity via
  `setModel`.

## (b) Friction (concrete)

1. **Identity is USD-prim-path-string-centric.** The whole selection API
   (`setSelection(_ path: String?)`, `userDidPick`, `selectedPrimPath`,
   `entity(for:)`, `primPath(for:)`, `USDPrimPathComponent`) is typed on **prim path
   strings**. We have opaque uuids, so we *shoehorn* uuids into path strings and
   decode them back out by string-splitting on `/`. There is no first-class opaque
   node-identity type.

2. **USD-import heritage leaks into a non-USD client.** Names and heuristics assume
   the entity tree came from `Entity(contentsOf:)`:
   - `USDPrimPathComponent`, "prim path" naming throughout.
   - `isGenericImportedName` treats leaves named `merged`, `merged_*`, `mesh`,
     `mesh_*` as importer noise and silently *remaps picks to a "semantic" sibling*.
     These names are meaningless for us, and the remapping could surprise an
     entity-source client whose uuids happen to collide with those prefixes.
   - `realityKitInternalNames` (`usdPrimitiveAxis`) and the `_N` duplicate-suffix
     stripping are USD-importer artifacts; harmless for us but extra surface.

3. **`setModel` does *not* cleanly bypass the URL/command load flow.** `setModel`
   injects the entity fine, but the *view* still assumes a `modelURL`-driven
   lifecycle: the pick gate, the `handleLoadRequestIfNeeded` task, and teardown all
   branch on `store.modelURL`/`activeLoadCommand`. We had to inject a **sentinel
   URL** purely to unlock picking. This is the single largest adoption wart.

4. **The "anonymous wrapper" contract is undocumented.** That `setModel` discards
   the top entity and only maps its children is implicit in
   `refreshPrimPathMapping`. Discovered empirically (the first integration test
   failed); a non-USD client has no reason to expect it.

5. **Externally-supplied `SceneBounds` is mandatory.** `restoreExternallySupplied
   SceneBounds` logs an error and clears bounds if none were supplied, which breaks
   camera auto-frame and the grid. We must compute bounds ourselves (walk the entity
   tree's `visualBounds`) and pad degenerate scenes to a frameable cube. A provider
   that can derive bounds from the injected entity when the host doesn't supply them
   would remove this obligation.

6. **TCA store coupling for a simple viewport.** Embedding `RealityKitStageView`
   requires constructing a `StoreOf<StageViewFeature>` even though our app is
   currently plain `@Observable` (not yet TCA). That pulls swift-composable-
   architecture into the app's dependency graph solely to render a viewport, and
   forces the host to learn the feature's action/state surface (load commands,
   request IDs) just to show entities.

7. **Local-path vs git-URL dependency.** We wire StageView as
   `.package(path: "../../../../../StageView")` so a developer checkout builds
   against an adjacent clone. That deep relative path is brittle (it assumes a fixed
   on-disk layout) and is **not** what an OSS/CI consumer wants. A release build must
   switch to `.package(url: "https://github.com/Reality2713/StageView.git", from:)`
   pinned to a tag. Maintaining both forms (and remembering to flip it) is friction.

8. **visionOS / cross-platform assumptions.** StageView targets macOS + iOS +
   visionOS; a large fraction of `RealityKitStageView` is `#if os(visionOS)` volume
   presentation, ornaments, `@available(visionOS 26)` gates, etc. Deconstructed 3 is
   **macOS-27-only**. None of it breaks us, but it is dead surface we compile and
   must reason around, and the `platforms` floor (`.macOS(.v15)`) is below ours.

9. **Viewport appearance doesn't follow the host color scheme.** With the default
   configuration the viewport renders **light even when the embedding app is in
   system Dark mode** (the rest of our window — sidebar, inspector — is correctly
   dark). `StageViewFeature.State.appearance` defaults to `.automatic`, which
   `StageViewAppearance.resolvedAppearance(for:)` resolves from
   `@Environment(\.colorScheme)` *inside* `RealityKitStageView` — but in our
   embedding that comes out light despite the app content being dark. Compounding
   it, the visible backdrop is the **skybox sphere** (`showEnvironmentBackground`,
   default `true`) drawing StageView's default environment *over* the appearance
   background — so even forcing `.updateAppearance(.dark)` doesn't darken the
   viewport; only `showEnvironmentBackground: false` lets the (appearance-colored)
   background show, at which point the scene loses its environment entirely. Net:
   "make the viewport match system dark mode" — which should be a one-liner —
   required reading the skybox + appearance internals, and we still could not get a
   clean theme-following result from the embedding side alone. **Deferred**: we ship
   the minimal default config and leave the viewport theming open.

## (c) Proposed StageView improvements (constructive)

These would make StageView pleasant to adopt for **any entity source**, not just USD
imports — without losing the USD path.

1. **First-class opaque node identity instead of prim-path strings.**
   Introduce a generic `NodeID` (e.g. an opaque `Hashable`/`RawRepresentable`
   wrapper, or make the provider generic over an `ID`) and key
   `setSelection`/`userDidPick`/`selectedPrimPath`/`entity(for:)` on it. USD imports
   keep using prim-path-derived IDs; entity-source clients pass their own stable IDs
   (our uuids) with no string round-tripping. Provide a component like
   `StageNodeIDComponent<ID>` parallel to `USDPrimPathComponent`.

2. **A documented, first-class "inject an entity hierarchy" entry point, decoupled
   from the URL/command flow.** Make `setModel` a fully supported peer of the load
   path: a `RealityKitConfiguration.source = .injectedEntity` (or an
   `isExternallyDriven` flag) that makes the pick gate, teardown, and lifecycle tasks
   treat an injected model as "loaded" **without** requiring `store.modelURL`. This
   removes the sentinel-URL hack (friction #3). Equivalently, gate picking on
   `runtime.isLoaded && runtime.modelEntity != nil` alone.

3. **Document (and ideally make explicit) the anonymous-wrapper contract.** Either
   document that `setModel`'s argument is treated as an unnamed root whose children
   are mapped, **or** add an overload `setModel(rootNode entity:)` that maps the
   passed entity itself as the first node. A clear contract here would have saved a
   failing test (friction #4).

4. **Selection/pick API not tied to USD path semantics.** Make the generic-name
   remapping (`merged_`/`mesh_` → "semantic" sibling) **opt-in** via configuration
   (`pickResolution: .importerSemantic | .identity`). Entity-source clients want
   "pick the entity I clicked," full stop.

5. **A lighter init for entity-only use without the full TCA store.** Offer a
   convenience initializer that takes just the provider (and an optional selection
   `Binding`) and constructs/owns a default `StageViewFeature` store internally —
   so a non-TCA host can show a viewport without learning the feature's action set
   or importing the reducer surface directly (friction #6). The TCA-driven init
   stays for hosts that want full control.

6. **Optional host-free `SceneBounds`.** When no external bounds are supplied, let
   the provider derive bounds from the injected entity's `visualBounds` instead of
   logging an error and clearing them (friction #5). Hosts that *want* authored
   bounds still override via `setExternalSceneBounds`.

7. **Publish tagged releases / SemVer.** A tagged release stream makes the git-URL
   dependency (friction #7) the obvious default and lets consumers pin reproducibly,
   relegating local-path to active StageView development only.

8. **Make appearance follow the host color scheme by default, with a trivial knob.**
   Either (a) resolve `.automatic` from the embedding environment reliably (a macOS
   app in Dark gets a dark viewport with zero config), or (b) expose a simple
   `appearance:` input on `RealityKitStageView.init` / `RealityKitConfiguration` that
   takes a `ColorScheme` (or `.dark`/`.light`/`.system`) and themes **both** the
   solid background and the grid — without the caller needing to know about the
   skybox, `showEnvironmentBackground`, or `StageViewAppearanceOverrides`. "Pass the
   system appearance and the viewport themes itself" is the expected ergonomics
   (friction #9). A common workaround is a bespoke appearance mapper that builds a
   `.custom` appearance with light/dark background palettes — useful, but more than a
   simple adopter should need.
