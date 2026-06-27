# AGENTS.md — Norn

Guidance for coding agents working in this repo. `README.md` is the user-facing intro; the
build/tooling/architecture facts that matter for development live here.

## What Norn is

**Norn** is a native (Odin) bridge **deal generator** — a replacement for `deal.exe` (Thomas Andrews `deal`, TCL-scripted) used by the `bridge-bidding-system` deal simulations. It generates random bridge deals and filters them by acceptance predicates (reject sampling), emitting deals for analysis/HTML rendering.

Name: Norse fate-weavers who *deal out* destiny — ties to the bidding system's Scanian / Swedish-club (Nordic) heritage. See `DESIGN.md` for program design, DDS plans, and the rationale behind replacing `deal.exe`. The engine surface being replaced is documented in `deal319-reference.md`.

## Package layout

One Odin package per directory:

| Path | Package | Role |
|------|---------|------|
| `norn/` | `norn` | the library: engine + generic bridge evaluation. Has no `main` — imported by everything else. |
| `conditions/` | `conditions` | this system's bidding predicates (`is_strong_1c`, …), imports `norn`. The Odin port of `deal-simulations/deal-utils.tcl`. |
| `cmd/norn/` | `main` | the CLI executable (raw generation). Imports `norn`. Holds the operational scaffold (`main.odin`). |
| `examples/strong-1c/` | `main` | sample single-condition generator — the shape a deal-simulation program takes; imports `norn` + `conditions`. |

In-repo packages import each other by **relative path** (`import "../../norn"`), so no build flags are
needed. An *external* program (e.g. in the bridge repo's `deal-simulations`) would instead import via a
collection: `-collection:norn=<abs>/norn/norn -collection:conditions=<abs>/norn/conditions`.

Layering rule: `norn` is system-agnostic (knows `hcp`/`pattern`/`is_balanced`, not "strong 1C");
system policy lives in `conditions`; the actual jobs are `package main` programs that pick a
condition + count + output and call `norn.generate_accepted`.

## Toolchain (must be installed)

- **Odin** compiler on `PATH`.
- **just** (>= 1.32) — task runner; all workflows go through the `justfile`.
- **nushell** (`nu`) — the Windows `just` shell (`set windows-shell := ["nu", "-c"]`); non-Windows uses `bash`.
- **python** on `PATH` — required by the `format` task (walks the tree) and used by `just`'s `[script("python")]`.
- **odinfmt** on `PATH` — built from the [OLS](https://github.com/DanielGavin/ols) source (`odinfmt.bat`/`.sh`). OLS is the recommended editor language server (`ols.json` holds project collections).

## Commands

```shell
just run            # build + run the CLI (cmd/norn)   -> target/debug/norn.exe
just run_fastdebug  # -debug -o:speed                   -> target/fastdebug/
just run_release    # -o:speed                          -> target/release/
just example        # build + run examples/strong-1c
just lint           # odin check every package (-vet -strict-style); the gate
just format         # odinfmt -w every *.odin under the tree
just test [args]    # odin test every package with tests (norn, conditions, cmd/norn)
just test1 NAME     # run one named test in the norn library package
just clean          # rm -rf target, then recreate the dir tree
just diagnose       # verbose build of the CLI
```

- Pass program args after `--` (e.g. `just run -- --count 48 --seed 1234`).
- Build artifacts go under `target/{debug,fastdebug,release}/` (gitignore-style, like Cargo's `target/`). `mktarget_dirs` auto-runs before builds.
- Always run `just lint` + `just test` before considering a change done — `lint` is the type-check + vet + strict-style gate across all packages.

## cmd/norn/main.odin — operational scaffold (don't bury domain logic here)

`main()` (in `cmd/norn/main.odin`) is **operational setup only** (profiling, allocators, logging, telemetry, backtraces); it then calls `main_program()` (in `cmd/norn/app.odin`). `main_program` returns an exit code — it must NOT call `os.exit`, which would skip `main`'s deferred teardown (leak tracking, profiler flush, logger); `main` exits once, after cleanup. Keep deal-generation logic out of the CLI entirely — it lives in the `norn` library.

Compile-time switches via `-define:NAME=true` (Odin `#config`):

| Define | Default | Effect |
|--------|---------|--------|
| `TRACKING_ALLOCATOR_ENABLE` | **true** | tracks leaks / bad frees, reports on exit |
| `TIME_PROGRAM_DURATION_ENABLE` | false | logs total runtime on shutdown |
| `SPALL_ENABLE` | false | emit `trace.spall` profile (adds ~2s); spall-web viewer |
| `MIMALLOC_ENABLE` | false | swap global allocator to mimalloc (needs `mi` import wired up) |
| `BACKTRACE_ENABLE` | false | better backtraces + segfault handler (needs `back` import) |

Runtime: `LOG_LEVEL` env var sets the console logger level (enum name, e.g. `Debug`/`Info`/`Warning`/`Error`; defaults to `Info`).

Note: `mimalloc` and `back` imports are commented out in `main.odin` — wire them in before enabling those defines.

## Editor files

- `ols.json` — OLS language-server config (project collections; currently empty).
- `odinfmt.json` — formatter config.
- Sublime `*.sublime-build` / `.sublime-project` (if present) are optional; delete if unused.
