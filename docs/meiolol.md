# zjb for meiolol

The `meiolol` branch: upstream zjb plus what meiolol needs to write all its browser code in
Zig (tpl components compiled to one ui.wasm that drives the DOM through zjb). Rules:

- Changes stay general purpose and in upstream's style, so each could be offered upstream
  on its own. meiolol's own helpers (a `dom.zig` with byId, setHtml, on(event),
  fetchText, storage) live in meiolol, not here.
- `main` is upstream plus the Zig 0.17 fix and the upstream watcher
  (.github/workflows/upstream.yml); this branch sits on `main`.

## Ranking

Pain points from the island spike (meiolol research/raw/zjb-tpl-island-spike.md), ranked by
value to meiolol against cost.

| # | Improvement | Value to meiolol | Cost | State |
| --- | --- | --- | --- | --- |
| 1 | Generated loader: one script tag, no hand-written JS | high | low | done |
| 2 | Read JS strings and bytes into Zig memory | high | low | done |
| 3 | Callback context (`bind`), so promise chains carry state | medium-high | very low | done |
| 4 | Handle scopes: release a callback's handles at once | medium | medium | open |
| 5 | Promise steps without one export each (fetch, then text) | medium | medium | open |
| 6 | Release builds: a trace or names on trap | low-medium | low to medium | open |
| 7 | Batch DOM ops into one buffer | low | high | not planned |
| 8 | ES module output (upstream issue #11) | low | low | open |

1. **Loader.** `generate_js out.js Zjb app.wasm --loader` adds `Zjb.load(source,
   imports)` and runs a script tag with `data-wasm` (relative to the script) and optional
   `data-main` (default `main`); `Zjb.ready` resolves to the bridge. Without the flag the
   output is unchanged. Adds 275 B gzip to the generated file and removes the last
   hand-written JS. Hashing works: hash the wasm first, then put its name in the HTML.
2. **Strings and bytes.** `Handle.readString(buf)`, `allocString(allocator)`,
   `readBytes(buf)`, `allocBytes(allocator)`, built to the maintainer's own design in
   upstream issue #2: methods on the handle, allocator passed in, NoSpaceLeft when a slice
   is too small, string into a slice through `encodeInto` on a view of just that slice,
   string allocation through an encoded Uint8Array. One crossing for the slice forms,
   three for the alloc forms. The JS views are made after allocating, so memory growth is
   safe (tested with a 6 MB string).
3. **Context.** `Handle.bind(args)` is `fn.bind(null, ...args)`: an exported callback gets
   a context value (an index into Zig state) first. A fetch then text chain is two bound
   callbacks, each carrying the request's index. No new JS needed.
4. **Handle scopes.** Handle ids only grow, so a scope could record the next id and
   release every id at or above it on exit. The catch: ConstHandles (`constString`,
   `global`, `fnHandle`) are created lazily on first use, possibly inside a scope, and
   would be released with it. Needs const handles pinned on the JS side (a set the range
   release skips) and an escape for a value that must outlive the scope (V8's
   EscapableHandleScope). meiolol's `dom.zig` can own every release instead, so pages
   never see a handle; do this only if that proves leaky.
5. **Promise steps.** `then` needs a function, and calling a method on the result (`r =>
   r.text()`) needs an export per step today. A generated `then_<method>` import kind would
   cover it, but bound callbacks (3) already work; wait for real use.
6. **Release traps.** `.strip = false` keeps DWARF as well as names: the example goes from
   12 KB to 632 KB, so it is a debugging build, not a shipping one. Keeping only the name
   section needs a post-link step. Also: `zjb.panic` has the deprecated root `panic`
   function signature; a namespace (`std.debug.FullPanic`) form would be the 0.17 way.
7. **Batching.** Fast designs (Ziex) batch DOM ops into one buffer, but meiolol renders
   whole HTML strings with tpl and sets `innerHTML` once per update, which is already one
   crossing. Revisit only if profiling shows crossings matter.

## Also fixed on this branch

- `constString("")` counted a handle that was never created, so `unreleasedHandleCount`
  underflowed (a panic in safe builds) once one was used.
- The global handle is `globalThis`, not `window`, so the bridge runs in workers and node.

## Tests

`zig build test` builds test/main.zig to wasm, generates the bridge with `--loader` and
runs test/run.mjs in node: the loader (URL resolution, main call), every new method, memory
growth, bind and a promise callback, and that no test leaves a handle unreleased. Upstream
issue #3 asks for tests with no external dependencies and Windows support; node on PATH
meets the second, not the first, so offering them upstream needs that discussed.

## Offering upstream

Each piece is its own commit: strings (issue #2), the `constString("")` and `globalThis`
fixes, bind, the loader (pairs with issue #11), tests (issue #3). Offer them one at a time
once upstream is on 0.17.
