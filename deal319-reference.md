# deal319 Reference — the engine Norn replaces

Notes on the Thomas Andrews `deal` v3.1.9 distribution at `F:\bin\deal319`, focused on the surface
Norn must replicate. This is the program our bridge `.tcl` simulation scripts currently drive.

## Distribution layout

```
deal319/
  deal.exe          the engine (C); links tcl85.dll
  tcl85.dll         embedded Tcl 8.5 interpreter
  deal.tcl          startup script sourced at boot (see "Startup" — locally customised!)
  lib/              the Tcl standard library of evaluators, shapes, scoring, hand types
  input/*.tcl       generation methods (how deals are produced / biased)
  format/*          OUTPUT formatters — extension-less Tcl files (the "tcl with no .tcl")
  ex/*.tcl          example condition scripts
  tests/, html/     test suite and the HTML manual (reference.html is the command reference)
  out.north/.east/.south/.west   sample output fragments
```

The **extension-less files** the engine loads are:
- `format/*` — 14 output formatters: `default none pbn par parArticle gibpar count numeric okb
  simpleokb onehand article practice ddline`. Each defines a `write_deal` proc. Selected with
  `deal -i format/NAME` (or by sourcing). `format/none` = no output; `format/default` = the ASCII
  table with optional unicode suit symbols.
- top-level `CHANGES GPL LICENSE` and the `out.*` samples (not code).

## Startup chain

`deal.exe` sources the stock `deal.tcl`, which:
1. sets `tcl_library`,
2. `source lib/features.tcl` (core namespace, shape conditions, the input loader, double-dummy
   `tricks`),
3. `source format/default` (the active output format).

Startup is stock — it does **not** load our helpers. Instead, each **condition script** pulls in
`deal-utils.tcl` itself and defines `main { ... }`. Two sourcing patterns are seen in our scripts:
- script-dir relative: `source $script_path/deal-utils.tcl` (e.g. `scratch.tcl`);
- via env var: `source $env(BRIDGE_TCL_UTILS_DIR)/deal-utils.tcl` (e.g. the user's
  `strong-club.tcl`).

(`strong-club.tcl` in the deal319 dir is the user's own example, not a canonical deal idiom — treat
it as illustrative only.) The authoritative predicate set is whatever our
`deal-simulations/deal-utils.tcl` defines, reviewed separately.

## The condition DSL (what scripts use → what Norn must provide natively)

A script body is `main { ... accept / reject ... }`, run once per generated deal — i.e. reject
sampling. Inside, the vocabulary is:

### Hands and suit lengths
- `north east south west` → a hand; `full_deal` → list of all four.
- `spades hearts diamonds clubs $hand` → suit length (int). Also usable as the "suit" argument to
  many procs, e.g. `[Top3 $hand spades]`.
- `partner $hand`.

### Point / trick evaluators
- `hcp $hand` (4-3-2-1), `controls` (A=2,K=1), `losers` (basic LTC), `newLTC` (new LTC, half-units),
  `dhcp` (distribution-adjusted hcp), `newhcp`, `OP` (offensive potential = offense − defense per
  suit, summed), `CCCC` (Danil Suits quality+distribution), `Quality`.
- `holdingProc NAME {A K Q J T x9 ... len} {body}` defines a **per-suit** evaluator over
  honour-presence flags (booleans `A K Q J T`, lower spot cards `x9 x8 …`) plus `len`; the engine
  maps it across the four suits. This is the core extension mechanism — most evaluators above are
  built this way.
- Honour vectors via `defvector`: `Ace King Queen Aces AceKing JT Honors Top1..Top7 Top5Q`, used as
  `[Top3 $hand $suit]` → count of top-3 honours held in that suit.

### Shape
- Builtins: `balanced` (`shapecond`: no 5-card major-ish, `s²+h²+d²+c² ≤ 47`), `semibalanced`,
  `AnyShape`; longest-suit classes `spade_shape heart_shape diamond_shape club_shape`.
- Define your own: `shapeclass` / `shapecond` (boolean) / `shapefunc` (numeric) over `$s $h $d $c`;
  `patternclass`/`patterncond` over the *sorted* lengths.
- Combine: `joinclass` (OR), `intersectclass` (AND), `negateclass` (NOT).
- `nt $hand min max` = balanced and hcp in range; opener heuristics `thomas_opener`,
  `sound_opener`, `roth_opener`, `gambling_nt`, `standard_opening_suit`, `solid_suit`.

### Double-dummy / scoring (deferred for Norn — see DESIGN.md)
- `tricks $declarer $denom` (cached, via the embedded DDS in `lib/ddeval.tcl`), `dds_reset`,
  par scoring in `lib/parscore.tcl` and `lib/score.tcl`.

## lib/ contents

| File | What |
|------|------|
| `evaluators.tcl` | `holdingProc` evaluators: defense, offense, OP, Controls, HCP, HC321, Quality, CCCC, Losers table |
| `utility.tcl` | `nt`, opener heuristics, `dhcp`/`newhcp`, `defvector` honour vectors, `partner`, `distinct_cards` |
| `features.tcl` | startup namespace, `shapecond balanced/semibalanced/AnyShape`, class combinators, `tricks`, `newLTC`, `patternclass/func/cond` |
| `shapes.tcl` | longest-suit `shapeclass`es |
| `handProc.tcl` / `handFactory.tcl` | hand accessor codegen; shape+value-biased hand construction |
| `ddeval.tcl` | double-dummy solver glue (the `tricks` engine) |
| `parscore.tcl` / `score.tcl` | par and contract scoring |
| `gib.tcl` / `binky*.tcl` | GIB library / "binky" bidding-ish helpers |

## input/ generation methods

`deal input NAME args` sources `input/NAME.tcl` and calls `NAME::set_input`. Methods: `line`, `pbn`,
`ddline`, `giblib`, `symmetric`, `smartstack`, `test`.

**`smartstack`** is the key one for Norn's future performance: given a `shapeclass`, a valuation
(e.g. `hcp`), and a value range, it biases generation toward hands matching a shape/strength via
`handFactory`, instead of brute reject-sampling rare hand types. This is deal's analog of redeal's
`SmartStack` — the model to follow when a predicate's accept rate gets too low.

## Relevance map for Norn

| deal319 piece | Norn counterpart |
|---------------|------------------|
| condition DSL (`hcp`, `controls`, `Top3`, shape classes, `balanced`) | native predicate procs (port from `deal-utils.tcl` + these builtins) |
| `main { accept/reject }` | acceptance predicate + reject-sampling loop (next milestone) |
| `format/*` write_deal scripts | the `render.odin` layer (`Output_Format`); `line`/`numeric`/`pbn` worth replicating |
| `-l` line output | already implemented (`Output_Format.Line`) |
| `smartstack` + `handFactory` | shape-biased generation (later perf work) |
| `tricks` / `ddeval` / par | DDS FFI (later; see DESIGN.md) |

The verbatim predicate set our scripts actually use lives in our `deal-simulations/deal-utils.tcl`
(reviewed separately) — that, plus the builtins above, is the exact API to port.
