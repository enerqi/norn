# Norn — Design Notes

Native bridge deal generator (Odin), replacing `deal.exe` (Thomas Andrews `deal`, TCL-scripted) for the `bridge-bidding-system` deal simulations.

## Why replace deal.exe

`deal.exe` is slow mainly from **per-deal TCL interpretation + reject sampling** on rare conditions — not the actual dealing. The existing `.tcl` scripts (in the bridge repo's `deal-simulations/`) are all simple **accept/reject predicates** (e.g. `is_strong_1c north`), with **no double-dummy** used. So a native generator with predicates written directly in Odin is a real, large speedup for little code.

## Core (small — the whole point)

Dealing is trivial; the value is native predicates instead of an interpreted DSL.

```
deck[52] := 0..51                  // card = suit*13 + rank
loop:
  fisher_yates(deck, predealt)     // partial shuffle, respecting predealt cards
  split into 4 hands (13 each)
  if predicate(hands): accept, output
  until count reached
```

- Predicates are **Odin procs**, ported from `deal-utils.tcl` helpers (hcp, suit lengths, shape, controls, `is_strong_1c`, etc.).
- Support **predeal** (fix some cards) — needed by some scripts.
- Output: line format compatible with the bridge repo's `run-deal.py` parser (`north|east|south|west`, space-separated suits), so existing HTML / BBO-handviewer rendering keeps working. Consider emitting handviewer params / HTML directly later.

## Performance reality

Pure generation (no double-dummy) = millions of deals/sec. Even rare conditions (strong-1C ~3% accept → ~33 deals/accept) are trivial. Will crush `deal.exe` regardless.

For rare hand types, the real lever is **shape-biased generation** (predeal / weighted shape, like dealer's `predeal` or redeal's `SmartStack`), not raw speed — only add if a predicate's accept rate gets painfully low.

## Double-dummy (only if/when needed)

Current sims don't need it. If makeable-tricks analysis is added later, the DDS solve dominates 100%+ and dealing speed becomes irrelevant.

- Use **Bo Haglund's DDS**. It is C++ internally but exposes a **C ABI** (`dll.h`, `extern "C"` + `DLLEXPORT`), so Odin can `foreign import` `dds.dll` / `libdds.so` and redeclare the POD structs.
- Entry points: `SolveBoard`, `SolveAllBoards`, `CalcDDtable` (20-cell table), `CalcAllTables`, `Par`/`DealerPar`, `SetMaxThreads`.
- Structs: `deal`, `ddTableDeal`, `futureTricks`, `ddTableResults`, `parResults` (cards as suit/rank bitfields).
- Gotchas: call `SetMaxThreads(0)` once at startup (auto-detect cores); reuse the transposition-table cache across boards (don't re-init per deal); Windows ships `dds.dll`, Linux/Mac build `libdds` from source.
- Reference: Rust's `dds-bridge` / `dds-bridge-sys` crates do the same FFI over `dll.h`. (`rustdds` is unrelated — networking, not double-dummy.)

## Existing alternatives (considered)

| Tool | Lang | Why not |
|------|------|---------|
| **dealer** (van Staveren) | C + custom DSL | fast, but another interpreted condition language to learn; core deal loop is only ~300–500 lines anyway |
| **dealerv2** | C + DSL + DDS | bundles double-dummy; heavyweight, DSL |
| **redeal** | Python predicates + DDS | flexible, `SmartStack`; good fallback, but slower than native and a separate runtime |

Chose native Odin: predicates in a real language, no interpreter, max throughput, and it unifies with a from-scratch design we control.

## Conditions as code

A condition is Odin code, not an interpreted script. `Predicate :: proc(summary: Deal_Summary) -> bool`
is the equivalent of a `deal` Tcl `main { accept/reject }` body; it reads one or more seats (multi-seat
conditions are common — opener + responder) using the `summary.odin` primitives (`hcp`,
`suit_length`, `pattern`/`shape`, `top_count`, `is_balanced`, losers, …) over the per-seat
`HandSummary` bitmask index (built once per board, see `summary.odin`). `generate_accepted` runs
the reject-sampling loop over a predicate. The `deal-utils.tcl` predicates port on top of these
primitives — that port (and the named-scenario registry built from it) lives in the *consumer*
bidding-system project, keeping `norn` itself system-agnostic.

## Structure (built)

The split anticipated here has shipped. The reusable core is I/O-free and free of process-lifecycle
assumptions so it can be embedded and called repeatedly:

- **Library / framework / consumer.** The engine (cards, deal, shuffle, render, evaluate, generate)
  is the `norn` package; a generic CLI + scenario framework is the `cli` package; the bidding policy
  (predicates + the scenario registry) lives in a separate consumer program that wires its registry
  into `cli.main_program`. See `AGENTS.md` for the package layout.
- **Many generators in one binary.** The scenario registry is exactly this: one program holds many
  conditions and runs the generator (or HTML export, or frequency measurement) per scenario. This is
  why generation is a plain reusable proc — no `os.exit`, no global one-shot state.
- **Frequency mode** measures each scenario's accept rate over N deals without rendering, seeding
  each scenario independently so the result is reproducible and identical whether run on one core or
  many (it parallelises across physical cores).
- **Predeal** (`--predeal "N:AS,KS S:QH"`) fixes chosen cards to seats and deals the rest at random
  around them — a deal conditioned on the fixed holdings, still uniform over the free cards. Lives in
  `norn/predeal.odin` and threads through every generation path (plain, html export, frequency).

- **SmartStack** (`norn/smartstack.odin`) biases ONE seat to a shape-set + hcp-range, building that
  hand directly from the constraint instead of reject-sampling for it — uniform over the admitted
  hands via exact importance sampling (count every matching hand in closed form, then sample with
  that conditional probability). The rare part of a condition is solved up front; any remaining
  multi-seat predicate still reject-samples on top. Threads through the same generation paths as
  predeal (`--frequency` included) via an optional `^Smart_Stack`. Build with `smartstack_make` /
  `smartstack_make_filtered`. v1 is single-seat, hcp-only evaluator; a general point vector and
  multi-seat stacking are possible later (the honour-distribution machinery generalises).

SmartStack is driven from the command line by `--smartstack "SEAT HCP SHAPE[/SHAPE...]"` (HCP:
`lo-hi | N | N+ | N-`; SHAPE: a keyword `balanced|semibalanced|any` or four S,H,D,C length fields,
each `N | N+ | N- | x`, with `/` unioning alternatives). It cannot be combined with `--predeal`.

## Parallelism

Scenarios are independent, so the **batch** commands fan out across physical cores:

- **`--frequency`** (`measure_frequencies`) and **`--html-dir`** (`export_all_html`) both run one task
  per scenario on a `thread.Pool` (one thread per physical core, capped at the scenario count). Each
  task owns its RNG (a local Xoshiro seeded by `scenario_seed(base, index)`), its builder, and its
  result slot — no shared mutable state in the hot loop. Output is therefore **identical on 1 core or
  N**, and reproducible from `--seed`. HTML writes a separate file per scenario (N independent sinks,
  no output contention); frequency concatenates its table on the main thread after the join.
- These are the **only** two multi-scenario paths. Every other format reaches output through `run`,
  which is a **single** scenario (or `accept_all`) — one ordered stream, nothing to fan out.

**Invariant to keep: one pool per command, leaf tasks only.** Tasks are single-threaded; to use more
parallelism, emit more tasks into the same pool — never spawn a pool inside a task. Nesting pools
would give N×N OS threads (each `pool_init` spawns `thread_count` threads that are then reused across
tasks). Real cross-thread cost here is not the pool's queue mutex (negligible at this coarse task
granularity) but the shared heap allocator on builder growth — mitigated by presizing builders
(`output_size_hint`); if it ever shows under profiling, switch to mimalloc (per-thread heaps,
`MIMALLOC_ENABLE`) and drop the tracking allocator (`-define:TRACKING_ALLOCATOR_ENABLE=false`), not
the pool.

**Single-scenario generation is left serial, deliberately.** A lone scenario in `run` has no
cross-scenario axis; the only speedup would be a fine within-scenario axis (probe the accept rate,
then shard the `count` quota across cores). Skipped because it almost never matters: norn deals
millions/sec, even a rare ~55-per-million accept rate fills the handful of deals a human actually
reads near-instantly. If it's ever wanted, build it under the same invariant — `run` has no outer
pool, so its own pool can't nest — by probing single-threaded first, then running N quota-shard tasks
(seeded per shard) in one pool and concatenating the shard buffers in index order.

## Ported from deal (the evaluator surface)

The generic evaluation vocabulary the bidding-system scripts use is ported into `norn/summary.odin`
(alongside the `HandSummary` index the evaluators run on): suit lengths, `hcp`, `controls`,
`top_count` (deal's `TopN`, now up
to Top7), `top5q`, `shape`/`pattern`, `is_balanced`/`is_semibalanced`/`is_nt5cM_shape`, the four
longest-suit classes `is_spade_shape`/`is_heart_shape`/`is_diamond_shape`/`is_club_shape`, `is_nt`
(deal's `nt min max`), `losers`, `offense`/`defense`/`op`, `dhcp`, `new_ltc`. The system-specific
predicates built on top live in the
consumer (see the library boundary), not here.

**Deliberately NOT ported** (no current sim uses them; record kept so the choice is intentional, not
forgotten):

- `newhcp` — per-suit adjusted point count; fiddly, unused. Add if a predicate ever needs it.
- `CCCC` / `Quality` — Danil-Suits shapepoints + holding evaluation; large, niche, unused.
- DDS-dependent output formats (`par`, `ddline`, …) and the niche `count` (= norn's `--frequency`),
  `okb`, `onehand`, `article`, … ; `symmetric` generation; reading PBN/giblib deals back in.
- Double-dummy (`tricks`, par scoring) — deferred to the DDS plan above, not dropped.

## Integration with bridge-bidding-system

The bridge repo (`~/docs/bridge/bridge-bidding-system`) drives deals via `deal-simulations/run-deal.py`
and `regen-html-deals.py`. Those scripts may still be used to scaffold/drive multiple generation
tasks in future. Keep Norn's text output format compatible so they (and the `just run-scratch` /
`just regen` recipes) can swap `deal.exe` → `norn` with minimal change. Broader background: that
repo's `deal-simulations/deal-generator-notes.md`.
