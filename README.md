# Norn

A fast bridge deal generator. Norn deals random bridge hands and keeps the ones matching a condition you describe — for practising auctions, running bidding-system simulations, and building deal sets.

It is a native replacement for the TCL-scripted [`deal`](http://bridge.thomasoandrews.com/deal30/), with conditions written in code instead of an interpreted scripting language.

> **Status: early / work in progress.** The project is scaffolded; the generator is not usable yet. Expect the interface below to change.

## What it will do

- Generate large numbers of random deals quickly.
- Accept/reject each deal by a condition (high-card points, suit lengths, shape, controls, …).
- Pre-place specific cards (predeal) and bias toward rare shapes so uncommon hand types still generate fast.
- Output deals in a plain text format that existing tools can turn into HTML / [BBO handviewer](https://www.bridgebase.com/tools/handviewer.html) pages.

## Building from source

Norn is written in [Odin](https://odin-lang.org/). See **[AGENTS.md](AGENTS.md)** for the toolchain and `just`
build/test commands.

## Name

The Norns are the Norse weavers of fate who *deal out* destiny — fitting for a hand dealer. The name nods three ways:
to [Odin](https://odin-lang.org/), the language it's written in (itself named for the Norse god); to the Nordic
(Scanian / Swedish-club) bidding system it was in part built to simulate; and to the act of dealing fate that the Norns
preside over.
