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
just test [args]    # odin test the packages with tests (norn, cli)
just test1 NAME     # run one named test in the norn library package
just clean          # rm -rf target, then recreate the dir tree
just diagnose       # verbose build of the CLI
```

- Pass program args after `--` (e.g. `just run -- --count 48 --seed 1234`).
- Build artifacts go under `target/{debug,fastdebug,release}/` (like Cargo's `target/`). `mktarget_dirs` auto-runs before builds.
- Always run `just lint` + `just test` before considering a change done — `lint` is the type-check + vet + strict-style gate across all packages.

**Scenario flags need a registry.** `--scenario`, `--list`, `--html-dir`, and `--frequency` operate on the scenario registry. The bare `cmd/norn` binary ships a nil registry, so those flags have nothing to act on — exercise them from a consumer (`odin-sims`) or a throwaway program that passes its own `[]cli.Scenario` to `cli.main_program`. `--frequency N` measures each scenario's acceptance rate over N deals (no deals emitted) and parallelises across physical cores.

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

## Editor files

- `ols.json` — OLS language-server config (project collections).
- `odinfmt.json` — formatter config.
- Sublime `*.sublime-build` / `.sublime-project` (if present) are optional; delete if unused.
