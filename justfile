# `cmd.exe` for one reason: it starts in ~9ms. just launches a shell per recipe line, so startup is a
# fixed tax on every build. Bare `<shell> exit` under hyperfine: cmd ~9ms, `nu -c` ~41ms (what this
# file used to set), `powershell -NoLogo -NoProfile -Command` ~143ms. cmd also wins the portability
# argument that made nu a bad default: it is on every Windows and on GitHub's windows runners, needs no
# install, and has no profile to make a recipe unreproducible. The cost is that it is a poor language
# for a multi-line recipe - which does not bite, because every Windows body below is a single command.
set windows-shell := ["cmd.exe", "/c"]
set shell := ["bash", "-c"]
set unstable
set lazy

# Set by the newest just feature used below - currently user-defined functions (1.49), for
# `target_path`. Older features it also needs: `join()` 1.37, f-strings 1.44, `set lazy` 1.47.
# Without this an old just reports a plain syntax error at the offending line, which reads like a
# corrupt justfile rather than an out-of-date tool.
set minimum-version := "1.49.0"

# The CLI binary is a single-file program (cmd/norn.odin, built with -file); the library lives in
# the norn package. The `-file` is baked in here so every recipe that builds it stays in sync.
#
# SCOPE OF THE `run*` RECIPES: they build cmd/norn.odin, which passes a NIL scenario registry, so they
# are the PURE GENERATOR — --count/--format/--output/--seed/--predeal/--smartstack/--fixed-table. The
# scenario flags (--scenario, --list, --html-dir, --frequency) parse but have nothing to act on; each
# reports an empty registry. Nothing in this repo supplies one — `example`/`example2` bypass the CLI
# entirely, calling norn.generate_accepted with a hardcoded predicate. To exercise the scenario flags,
# run a consumer that owns a registry (deal-simulations/odin-sims in the bridge-bidding-system repo).
cli_pkg := "cmd/norn.odin -file"
main_name := "norn.exe"
test_main_name := "test-main.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted. Odin takes either in an
# `-out:` argument, but the `rerun_*` recipes invoke the binary directly, so they need the native
# separator `join` gives. bash needs no `./` prefix - a path containing a slash is already a path.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to. `-linker:` takes exactly four values: `default` (Odin
# picks - MSVC `link.exe` on Windows), `lld` (Windows and Linux; NOT on a stock macOS, where Odin
# links through Apple's clang and clang ships no lld), `radlink` (Windows only, and bundled with the
# Odin toolchain so it needs no install - which is why it is the Windows default here) and `mold`
# (Linux only, and not bundled - `apt install mold` first). Odin has no build cache and relinks on
# every `just run`, so the link step is a cost paid on each iteration.
#
# Override for a single command without editing this file. It is an env var rather than a recipe
# argument because `odin` errors on a repeated flag, so a `-linker:` passed through a recipe's *args
# would collide with the one the recipe already adds:
#
#     ODIN_LINKER=lld just run_release -lto:thin   # -lto on Windows *requires* -linker:lld
#
# See the odin-lang-skeleton justfile for the full per-value notes.
linker := env_var_or_default("ODIN_LINKER", if os() == "windows" { "radlink" } else { "default" })

# odinfmt every .odin file under this directory (odinfmt walks subdirs itself)
format:
	odinfmt -w .


# lint checks for style and potential bugs across every package. Accepts extra args like
# `--show-timings` as needed. Library packages need -no-entry-point; the program packages do not.
# ---
# type check + vet + strict style across all packages
lint *args:
	odin check norn -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check cli -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check combo -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check {{cli_pkg}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check cmd/bench.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check examples/strong-1c.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check examples/1major-gf-support.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}


# Every `run_*`, `test*` and `diagnose` recipe depends on this, so it runs before every build - which
# makes its cost a tax on every iteration. The directories are created all at once rather than one per
# line because just starts a new shell per recipe line and on Windows the shell launch dwarfs the work.
# odin does not create the output directory (the linker fails with LNK1104), so this cannot be dropped.
# ---
# ensure the build artifacts top level directory exists
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop variable is a single `%d`, NOT the `%%d` a .bat file would use:
# doubling is escaping for batch *files*, and `cmd /c` takes a command *line*.
# ---
# ensure the build artifacts top level directory exists
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# run the CLI with a debug build. `--` separates the program's args from odin's own flags.
# `-keep-executable` leaves the built binary in place (odin run deletes it by default) so `rerun_debug`
# can execute it again without recompiling. `-debug` implies `-o:none`, so this is the fastest to
# compile and the friendliest to step through. Nil registry: generator flags only (see the header note).
# ---
# run the CLI, generator flags only - no scenarios in this build (debug build)
run_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("debug", main_name) }} -- {{args}}

alias run := run_debug

# `-o:minimal` is one rung above the `-debug` default of `-o:none`: still quick to compile and mostly
# faithful to step through, but noticeably faster at runtime.
# ---
# run the CLI with debug info and light optimizations
run_fast_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:minimal -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("fast_debug", main_name) }} -- {{args}}

# Release codegen with debug info retained: for profiling and for chasing bugs that only appear under
# optimization. Slowest to compile, and the debugger will jump around inlined/reordered code.
# ---
# run the CLI with full optimizations AND debug info
run_release_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release_debug", main_name) }} -- {{args}}

# run the CLI with optimizations
run_release *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release", main_name) }} -- {{args}}

# `run_release` plus every runtime safety check compiled out: `-no-bounds-check` (slice/array indexing),
# `-disable-assert` (the built-in `assert`) and `-no-type-assert` (union/any type assertions). Those
# checks are what turn a memory-corrupting bug into a clean panic, so a fault here is undefined
# behaviour rather than a readable message - benchmark against `run_release` before adopting it, and
# keep a checked build in your test matrix.
# ---
# run the CLI with optimizations and ALL runtime safety checks removed
run_release_nochecks *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -no-bounds-check -disable-assert -no-type-assert -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release_nochecks", main_name) }} -- {{args}}

# `address` (ASan) catches out-of-bounds accesses and use-after-free; `memory` catches reads of
# uninitialized memory; `thread` catches data races. Only `address` is widely supported - `memory` and
# `thread` need a clang-ish toolchain and are unavailable on some platforms (notably Windows/MSVC).
# Both sanitizer recipes deliberately omit `-linker:{{linker}}`: link speed is worth nothing on a
# diagnostic run, and pinning it actively breaks things. A sanitizer has to interpose on the runtime,
# which not every linker cooperates with - `radlink` (this file's Windows default, and bundled with
# Odin, so it is what you get by accident) links an ASan binary that dies on startup with a bare
# `0xc000001d` illegal-instruction exception and no usable stack, while `-linker:default` runs it.
# Usage:  just sanitize   or   just sanitize thread -- --count 4
# ---
# run the CLI under a sanitizer (address | memory | thread)
sanitize kind="address" *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{main_name}}") }} -- {{args}}

# same sanitizer options as `sanitize`; see its notes for platform support and the linker note.
# ---
# run the library tests under a sanitizer (address | memory | thread)
test_sanitize kind="address" *args: mktarget_dirs
	odin test norn -debug -file -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{test_main_name}}") }} {{args}}

# Odin has no build cache, so a plain `run` always rebuilds. Requires a prior `run_debug`/`run` build.
# ---
# re-execute the already-built debug binary WITHOUT recompiling
rerun_debug *args:
	{{ target_path("debug", main_name) }} {{args}}

alias rerun := rerun_debug

# re-execute the already-built fast_debug binary without recompiling (run `run_fast_debug` once first).
rerun_fast_debug *args:
	{{ target_path("fast_debug", main_name) }} {{args}}

# re-execute the already-built release_debug binary without recompiling (run `run_release_debug` first).
rerun_release_debug *args:
	{{ target_path("release_debug", main_name) }} {{args}}

# re-execute the already-built release binary without recompiling (run `run_release` once first).
rerun_release *args:
	{{ target_path("release", main_name) }} {{args}}

# re-execute the already-built nochecks binary without recompiling (run `run_release_nochecks` first).
rerun_release_nochecks *args:
	{{ target_path("release_nochecks", main_name) }} {{args}}

# NOT a CLI consumer: it hardcodes one predicate and calls norn.generate_accepted directly, so it
# takes no --scenario/--count flags - edit the source to change what it generates.
# ---
# run the example single-condition generator program (single-file, built with -file)
example *args: mktarget_dirs
	odin run examples/strong-1c.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:{{ target_path("debug", "strong-1c.exe") }} {{args}}

# Like `example`, it bypasses the CLI framework entirely (hardcoded predicate, no flags).
# ---
# run the multi-seat opener+responder example generator program (single-file, built with -file)
example2 *args: mktarget_dirs
	odin run examples/1major-gf-support.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:{{ target_path("debug", "1major-gf.exe") }} {{args}}

# run the scan-vs-bitmask-index hand-evaluation benchmark (release, optimised)
bench *args: mktarget_dirs
	odin run cmd/bench.odin -file -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench.exe") }} {{args}}

# run all tests in every package that has them
test *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-norn.exe") }} {{args}}
	odin test cli -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-cli.exe") }} {{args}}
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-combo.exe") }} {{args}}

# run only the card-combination analyser's tests (the `combo` package)
test-combo *args: mktarget_dirs
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-combo.exe") }} {{args}}

# Filtering is a `core:testing` define rather than a compiler flag - there is no `-test-name:`, and a
# stale spelling of one fails with `Unknown flag: 'test-name'` before anything builds. NAME takes a
# comma-separated list and the package prefix is optional, so `norn.my_test`, `my_test` and
# `one,two` all work:
#     just test1 my_test
# ---
# run one named test in the library package (comma-separated for several)
test1 name *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# simple delete of all debug databases and executables in the target directory
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's equivalent of `rm -rf` is `rmdir /s /q`. Guarded by `if exist` because rmdir prints "The
# system cannot find the file specified" and exits non-zero on a missing path, which would fail the
# recipe on an already-clean tree.
# ---
# simple delete of all debug databases and executables in the target directory
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs

# build the CLI with some verbose diagnostics
diagnose *args: mktarget_dirs
	odin build {{cli_pkg}} -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -linker:{{linker}} -out:{{ target_path("debug", main_name) }} {{args}}
