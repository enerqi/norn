# AGENTS.md — Norn

Guidance for coding agents working in this repo. `README.md` is the user-facing intro; the
build/tooling/architecture facts that matter for development live here.

## What Norn is

**Norn** is a native (Odin) bridge **deal generator** — a replacement for `deal.exe` (Thomas Andrews `deal`, TCL-scripted) used by the `bridge-bidding-system` deal simulations. It generates random bridge deals and filters them by acceptance predicates (reject sampling), emitting deals for analysis / HTML rendering, and can measure how often a predicate accepts.

Name: Norse fate-weavers who *deal out* destiny — ties to the bidding system's Scanian / Swedish-club (Nordic) heritage. See `DESIGN.md` for rationale (why replace `deal.exe`), the DDS plan, the ported/not-ported evaluator surface, and design trade-offs.

## Package layout

One Odin package per directory; the single-file programs are built with `-file`.

| Path | Package | Role |
|------|---------|------|
| `norn/` | `norn` | the library: engine (cards, deal, shuffle, predeal, smartstack, render, generate) + generic bridge evaluation over the `Hand_Summary` index (`summary.odin`). No `main` — imported by everything else. |
| `cli/` | `cli` | the reusable CLI framework: argument parsing (`cli.odin`), the `Scenario` registry type + lookup (`scenario.odin`), and the drivers (`run.odin`) for plain generation, HTML batch export, and frequency measurement. Entry point `main_program` is in `app.odin`. No `main`. Imports `norn`. |
| `combo/` | `combo` | the **card-combination analyser**: per-suit trick-chance distributions, named single-dummy lines with their odds, the convolution to a combined P(>= target), and the `Html_Cards` `.combo` blob the card page renders. Entry-free, suit-isolated model — solver-free by construction (no DDS anywhere) and the explanatory counterpart to a double-dummy solve. Ships **no** published suit-combination table: a consumer registers one through the `Suit_Book` hook (`book.odin`). Imports `norn`. |
| `cmd/norn.odin` | `main` | the CLI executable — operational scaffold only. Ships a **nil** scenario registry, so it is the pure deal generator (`--count`/`--format`/`--seed`). |
| `cmd/bench.odin` | `main` | scan-vs-bitmask hand-evaluation micro-benchmark. |
| `examples/strong-1c.odin`, `examples/1major-gf-support.odin` | `main` | self-contained single-condition demo programs — the shape a consumer takes; `norn` primitives only. |

**The system-specific predicates and the scenario registry are NOT in this repo.** They live in the *consumer* project (`~/docs/bridge/bridge-bidding-system/deal-simulations/odin-sims`, package `bidding`), which imports norn as a collection and wires its `registry` into `cli.main_program`. Keeping norn generic and the bidding policy out is the deliberate library boundary.

In-repo packages import each other by **relative path** (`import "../norn"`). An *external* consumer imports via a single collection rooted at the repo:

```
-collection:norn=<abs path to this repo>
import "norn:norn"
import "norn:cli"
```

Layering rule: `norn` is system-agnostic (knows `hcp`/`pattern`/`is_balanced`, not "strong 1C"); `cli` is the generic scenario + argument framework; the bidding policy (predicates + the `[]cli.Scenario` registry) lives in the consumer, whose `main` calls `cli.main_program(registry)`.

Same rule for `combo`: it is generic card-play mathematics (a holding is two `u16` masks; nothing in it
knows a bidding system), so it belongs here even though its output is consumed by the bidding-system card
pages — whose JS already lives here, in `norn/html_cards_*.tmpl`. What it deliberately does NOT carry is a
published suit-combination corpus: those tables are somebody's editorial work, so `combo/book.odin` defines
only the mechanism (`Suit_Book`, `set_suit_book`, `book_key`, `book_line_applies`) and the consumer supplies
the data (see the bidding system's `suit_book` package). Unregistered, combo reports its own engine line.

## Toolchain (must be installed)

- **Odin** compiler on `PATH`.
- **just** (>= 1.32) — task runner; all workflows go through the `justfile`.
- **nushell** (`nu`) — the Windows `just` shell (`set windows-shell := ["nu", "-c"]`); non-Windows uses `bash`.
- **python** on `PATH` — used by `just`'s `[script("python")]` (e.g. the consumer's `ols-config`).
- **odinfmt** on `PATH` — built from the [OLS](https://github.com/DanielGavin/ols) source (`odinfmt.bat`/`.sh`). OLS is the recommended editor language server (`ols.json` holds project collections).

## Commands

```shell
just run            # build + run the CLI (cmd/norn.odin, debug)  -> target/debug/norn.exe
just run_fastdebug  # -debug -o:speed                              -> target/fastdebug/
just run_release    # -o:speed                                     -> target/release/
just example        # build + run examples/strong-1c.odin
just example2       # build + run examples/1major-gf-support.odin
just bench          # hand-evaluation micro-benchmark (cmd/bench.odin)
just lint           # odin check every package + single-file program (-vet -strict-style); the gate
just format         # odinfmt -w every *.odin under the tree
just test [args]    # odin test the packages with tests (norn, cli, combo)
just test-combo     # only the card-combination analyser's tests
just test1 NAME     # run one named test in the norn library package
just clean          # rm -rf target, then recreate the dir tree
just diagnose       # verbose build of the CLI
```

- Pass program args after `--` (e.g. `just run -- --count 48 --seed 1234`).
- Build artifacts go under `target/{debug,fastdebug,release}/` (like Cargo's `target/`). `mktarget_dirs` auto-runs before builds.
- Always run `just lint`, `just format`, and `just test` before considering a change done — these are the quality gate. `lint` is the type-check + vet + strict-style check across all packages, `format` applies `odinfmt`, and `test` runs the package tests.

**Scenario flags need a registry — nothing in THIS repo has one.** `cmd/norn.odin` passes `nil` to `cli.main_program`, so `just run` / `run_fastdebug` / `run_release` / `rerun*` are the PURE GENERATOR: `--count`, `--format`, `--output`, `--seed`, `--predeal`, `--smartstack`, `--fixed-table`. The scenario-dependent flags parse but have nothing to act on:

| Flag | On the bare binary |
|------|--------------------|
| `--scenario NAME` | "unknown scenario" — there is no catalogue to look it up in |
| `--list` | prints the empty-registry notice (`write_scenario_list`) |
| `--html-dir DIR` | "no scenarios to export (registry is empty)" |
| `--frequency N` | "no scenarios to measure (registry is empty)" |
| `--dd` | parses, but the hooks are keyed by scenario name, so none can fire |

This is the library boundary working as intended, not a gap: the registry is the consumer's bidding policy. `examples/strong-1c.odin` and `examples/1major-gf-support.odin` do NOT fill the hole — they bypass the CLI framework entirely, calling `norn.generate_accepted` with a hardcoded predicate and taking no flags.

**So: any change to the scenario paths must be smoke-tested from a consumer**, not from `just run`. Use `~/docs/bridge/bridge-bidding-system/deal-simulations/odin-sims` (`just build` there, then `./target/release/sim.exe --list` / `--frequency 2000 -S <name>` / `--html-dir <dir> -S <name>`), or a throwaway `main` that hands `cli.main_program` its own `[]cli.Scenario`. `--frequency N` measures each scenario's acceptance rate over N deals (no deals emitted) and parallelises across physical cores.

## cmd/norn.odin — operational scaffold (don't bury domain logic here)

`main()` (in `cmd/norn.odin`) is **operational setup only** (profiling, allocators, logging, telemetry, backtraces); it then calls `cli.main_program(nil)` (the entry point lives in `cli/app.odin`). `main_program` returns an exit code — it must NOT call `os.exit`, which would skip `main`'s deferred teardown (leak tracking, profiler flush, logger); `main` exits once, after cleanup. Keep deal-generation logic out of the CLI entirely — it lives in the `norn` library, driven by `cli`.

Compile-time switches via `-define:NAME=true` (Odin `#config`):

| Define | Default | Effect |
|--------|---------|--------|
| `TRACKING_ALLOCATOR_ENABLE` | **true** | tracks leaks / bad frees, reports on exit |
| `TIME_PROGRAM_DURATION_ENABLE` | false | logs total runtime on shutdown |
| `SPALL_ENABLE` | false | emit `trace.spall` profile (adds ~2s); spall-web viewer |
| `MIMALLOC_ENABLE` | false | swap global allocator to mimalloc (needs `mi` import wired up) |
| `BACKTRACE_ENABLE` | false | better backtraces + segfault handler (needs `back` import) |

Runtime: `LOG_LEVEL` env var sets the console logger level (enum name, e.g. `Debug`/`Info`/`Warning`/`Error`; defaults to `Info`).

Note: `mimalloc` and `back` imports are commented out in `cmd/norn.odin` — wire them in before enabling those defines. The default tracking allocator is **not thread-safe**, so a thread-using path (e.g. `--frequency`) requires a thread-safe allocator; the bare CLI is safe only because its nil registry makes those paths a no-op.

## Odin style conventions

**Model disjoint unions as disjoint unions — no "flag + fields only valid when set".** If a group of
fields is meaningful only when some `has_x: bool` is true, that is a sum type written badly: the invalid
states (flag false but fields read, flag true but fields never filled) stay representable and every
reader must remember the gating rule. Pull the correlated fields into their own struct and hold it as
`Maybe(T)`; the compiler then forces the check at the point of use.

```odin
// NO — three fields silently garbage unless the flag is set.
Board :: struct {
	contract_level:  int,
	contract_strain: Contract_Strain,
	declarer:        Seat,
	has_contract:    bool,
}

// YES — one value, present or absent.
Contract :: struct {
	level:    int,
	strain:   Contract_Strain,
	declarer: Seat,
}
Board :: struct {
	contract: Maybe(Contract),
}

// Readers unwrap; there is no way to read the fields without the check.
if contract, ok := board.contract.?; ok { ... }
```

Same for a procedure returning a bundle of correlated values behind an `ok` — return `(T, bool)` (or
`Maybe(T)`), not `(a, b, c, ok)`. Use a `union` when the alternatives differ in SHAPE (several distinct
variants), `Maybe(T)` when it is simply present-or-absent, and an enum + `bool` pair only when the fields
really are independent.

A "kind enum + payload fields valid for one kind" struct is the same mistake in union clothing — see
`Auction_Call` in `norn/contract.odin`: only a bid carries a level/strain, so it is
`union {Auction_Bid, Auction_Pass, Auction_Double, Auction_Redouble}` (nil = junk token), unwrapped with
`bid, is_bid := call.(Auction_Bid)`, not a `kind: Auction_Call_Kind` beside always-present
`level`/`strain`.

### Writing the union: unit variants and `nil`

Odin unions are unions of TYPES — there is no inline-payload variant syntax (`union {Bid{level: int},
Pass}` does not exist), so a payload-free case needs a named type. A zero-size `struct {}` is that type:
it adds nothing to the union (`size_of(Auction_Pass) == 0`, and the whole union is 24 bytes — the same
as the flag+fields struct it replaced, because the tag lands in the payload variant's padding). A
`distinct u8` or a dummy field would only add a meaningless value to construct.

Pick the shape by how many variants carry data:

| Situation | Use |
|---|---|
| NO variant carries a payload | a plain `enum` — never a union of empty structs |
| ONE payload variant, few unit variants | `union {Payload, Unit_A, Unit_B}` (what `Auction_Call` does) |
| ONE payload variant, MANY unit variants | `union {Payload, Kind_Enum}` — an enum groups the unit cases, keeping package scope clean; both levels still switch exhaustively |
| the unit variants are never distinguished | `Maybe(Payload)` |

The cost of unit-variant structs is namespace pollution: Odin does not scope variant names, so
`Auction_Pass` sits at package level and must be prefixed by hand (an enum gives you `.Pass` for free).
That is what tips the choice to the enum-grouped form once the unit variants outnumber ~5.

**`nil` vs `#no_nil`.** Every union has a `nil` state unless declared `#no_nil`. Prefer plain `nil` as
the absent/invalid case and NAME it in the doc comment (`Auction_Call`: "a nil call is an unparseable
token"). Reach for `#no_nil` only when the first variant is a genuinely sensible default — it makes the
ZERO VALUE the first variant, so a zero-initialised `Auction_Call` would become `Auction_Bid{level = 0}`,
an invalid bid that type-checks. A documented absence beats a fabricated value. `#no_nil` does not
shrink the type either (measured: same 24 bytes).

**No sentinel values for "absent".** A `-1` index, an empty-string "no dealer", a magic `0` — all of
them are an absence the type system can't see, and they index/print/compare as if they were data. Use
`Maybe(T)`, or a second `ok` return (`weighted_pick`, `derive_contract`). Where the absence is
impossible by construction, assert it and say why rather than propagating the sentinel.

**Enum variant names: be consistent within the enum.** `Contract_Strain` is
`Clubs / Diamonds / Hearts / Spades / NoTrumps` — all plural; don't mix `NoTrump` in among plural suits.

## Big templates live in files, `#load`ed at compile time

A multi-kilobyte HTML/CSS/JS blob as an Odin raw literal is unreadable and unmaintainable: the editor
highlights it as one string, the formatter can't touch it, and the literal's delimiter leaks into the
content (the old `Html_Cards` header was written backtick-free — plain JS string concatenation instead
of template literals — purely to survive inside a `` ` `` literal). Put it in a sibling file and
`#load` it:

```odin
// norn/render.odin — the file sits beside this one; the path is relative to THIS source file.
@(private = "file")
HTML_CARDS_PAGE_HEADER :: #load("html_cards_header.html.tmpl", string)
```

`#load` is a COMPILE-TIME embed: the constant is the file's bytes, so there is no runtime file I/O, no
path to resolve at run time, and the binary stays self-contained (the whole point of the offline
`Html_Cards` page). Editors and linters see real HTML/CSS/JS, and the content needs no escaping —
backticks, quotes and `\` are all just bytes.

Conventions:

- Name them `<thing>.<real-extension>.tmpl` (`html_cards_header.html.tmpl`) — the real extension drives
  editor tooling, `.tmpl` says it is not a standalone page.
- Keep them beside the `.odin` that loads them; `#load` paths are relative to the source file.
- Substitute with an explicit token, not string formatting: the header carries `{{TITLE}}`, filled by
  `strings.replace_all(..., context.temp_allocator)` in `render_page_prologue`. `%`-style verbs in a
  file of CSS would be a minefield.
- Editing a `.tmpl` changes the binary, so rebuild before testing — nothing reloads it at run time.
- `just format` (odinfmt) does not touch them, and neither does `just lint`: a broken template is a
  BROWSER-visible bug, not a compile error. Verify page changes by opening a generated page.

Small fragments (the handviewer iframe prefix/suffix, a one-line footer) stay as inline literals — the
file indirection is only worth it once the blob is big enough to fight the editor.

## Distinct types over bare primitives

Odin code often passes `int`/`u16`/`string` around; this repo prefers a named type wherever a wrong
value of the same primitive type would still compile. The cost is a cast at the boundary, so apply it
where a mix-up is *plausible*, not everywhere:

- **A domain quantity with its own operations** → its own type. `Card :: distinct u8`;
  `Rank_Set :: bit_set[Rank; u16]` for a suit holding (`.Ace in ranks`, `card(ranks)`), with
  `rank_mask` / `rank_set` / `suit_mask` as the explicit escape hatches for code that genuinely wants
  the raw u16 (an external solver's own bit conventions).
- **Two same-typed parameters that could be swapped** → distinct types or one struct.
- **The same type in two different ROLES** → distinct types when the operations differ.
  `Opener`/`Responder` (`distinct Hand_Summary`) exist because the responder's base is capped and only
  the responder earns ruffing value; roles are decided in one place and the type carries the decision.
  Symmetric pairs (`opc_mirror_penalty(a, b)`, `combined_opc(a, b)` — which derives the roles itself)
  stay plain, and say so in the doc comment.
- **Not worth it**: blanket `distinct int` over every count (`hcp`, `controls`, `losers`, suit
  lengths). They are single-return, immediately compared or summed, and distinct types would force
  casts through every consumer predicate for no realistic safety win. Enums, `bit_set`s and
  enumerated arrays (`[Suit]T`, `[Seat]T`) are already distinct enough — don't wrap those further.

## Editor files

- `ols.json` — OLS language-server config (project collections).
- `odinfmt.json` — formatter config.
- Sublime `*.sublime-build` / `.sublime-project` (if present) are optional; delete if unused.
