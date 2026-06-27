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

## Conditions as code (current model)

A condition is Odin code, not an interpreted script. `Predicate :: proc(board: Deal) -> bool` is the
equivalent of a `deal` Tcl `main { accept/reject }` body; it reads one or more seats (multi-seat
conditions are common — opener + responder) using the `evaluate.odin` primitives (`hcp`,
`suit_length`, `pattern`/`shape`, `top_count`, `is_balanced`, …). `generate_accepted` runs the
reject-sampling loop over a predicate. The ~85 `deal-utils.tcl` predicates port on top of these
primitives.

## Planned structure (future, not built yet)

The reusable core is deliberately I/O-free and free of process-lifecycle assumptions so it can be
embedded and called repeatedly. Anticipated direction:

- **Library package split.** Move the core (cards, deal, shuffle, render, evaluate, generate) into a
  `norn` library package, leaving a thin `main` for the CLI. Then each condition — e.g. the bridge
  repo's `3n-opener.tcl` — becomes a small single-file Odin program that imports `norn`, defines its
  `Predicate`, and calls the generator. (Mechanical `package main` → `package norn` rename + a `cmd/`
  dir for the CLI; deferred until the API settles.)
- **Many generators in one binary.** Several conditions may be compiled into a single program that
  calls `generate_accepted` once per condition (different predicate / count / output each time). This
  is why generation is a plain reusable proc — no `os.exit`, no global one-shot state — rather than
  baked into `main`.

## Integration with bridge-bidding-system

The bridge repo (`~/docs/bridge/bridge-bidding-system`) drives deals via `deal-simulations/run-deal.py`
and `regen-html-deals.py`. Those scripts may still be used to scaffold/drive multiple generation
tasks in future. Keep Norn's text output format compatible so they (and the `just run-scratch` /
`just regen` recipes) can swap `deal.exe` → `norn` with minimal change. Broader background: that
repo's `deal-simulations/deal-generator-notes.md`; the engine surface to match is in
`deal319-reference.md`.
