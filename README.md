# Norn

A fast bridge deal generator. Norn deals random bridge hands and keeps the ones matching a condition you describe — for
practising auctions, running bidding-system simulations, and building deal sets.

It is a native replacement for the TCL-scripted [`deal`](http://bridge.thomasoandrews.com/deal30/), with conditions
written in code instead of an interpreted scripting language.

## What it does

- Generates large numbers of random deals quickly.
- Accepts/rejects each deal by a condition — high-card points, suit lengths, shape, controls, losers — written as an
  Odin predicate (reject sampling).
- Outputs deals as plain text, "pretty" tables, [BBO handviewer](https://www.bridgebase.com/tools/handviewer.html)
  query strings, or full HTML pages; batch-exports one HTML page per scenario.
- Measures how often a scenario's predicate accepts over many deals (`--frequency`), parallelised across CPU cores.
- Pre-places specific cards (`--predeal "N:AS,KS S:QH"`) and deals the rest around them.
- Biases one seat to a shape-set + hcp window (`--smartstack "N 20-21 balanced"`) so rare hand types
  still generate fast, building that hand directly instead of reject-sampling for it.
- Reproducible runs via `--seed`.

Conditions are organised as named **scenarios**. Norn itself is the generic engine + CLI framework; the concrete
bidding-system scenarios live in a separate consumer project that supplies its registry — so anyone can reuse Norn as a
hand-generation engine with their own conditions -
[examples](https://github.com/enerqi/bridge-bidding-systems/tree/master/deal-simulations/odin-sims).

Planned: optional double-dummy analysis (makeable tricks / par scoring). See [DESIGN.md](DESIGN.md).

## Building from source

Norn is written in [Odin](https://odin-lang.org/). See **[AGENTS.md](AGENTS.md)** for the toolchain and `just`
build/test commands.

## Name

The Norns are the Norse weavers of fate who *deal out* destiny — fitting for a hand dealer. The name nods three ways:
to [Odin](https://odin-lang.org/), the language it's written in (itself named for the Norse god); to the Nordic
(Scanian / Swedish-club) bidding system it was in part built to simulate; and to the act of dealing fate that the Norns
preside over.
