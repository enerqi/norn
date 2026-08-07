set windows-shell := ["nu", "-c"]
set shell := ["bash", "-c"]
set unstable  # [script("python")] feature - https://github.com/casey/just/issues/1479

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


# ensure the build artifacts top level directory exists
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fastdebug target/release

# ensure the build artifacts top level directory exists
[windows]
@mktarget_dirs:
	mkdir target/debug target/fastdebug target/release

# run the CLI with a debug build. `--` separates the program's args from odin's own flags.
# `-keep-executable` leaves the built binary in place (odin run deletes it by default) so `rerun_debug`
# can execute it again without recompiling. Nil registry: generator flags only (see the header note).
# ---
# run the CLI, generator flags only - no scenarios in this build (debug build)
run_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:target/debug/{{main_name}} -- {{args}}

alias run := run_debug

# run the CLI with debug and optimizations
run_fastdebug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:target/fastdebug/{{main_name}} -- {{args}}

# run the CLI with optimizations
run_release *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:target/release/{{main_name}} -- {{args}}

# re-execute the already-built debug binary WITHOUT recompiling (run `run_debug` once first).
rerun_debug *args:
	./target/debug/{{main_name}} {{args}}

alias rerun := rerun_debug

# re-execute the already-built fastdebug binary without recompiling (run `run_fastdebug` once first).
rerun_fastdebug *args:
	./target/fastdebug/{{main_name}} {{args}}

# re-execute the already-built release binary without recompiling (run `run_release` once first).
rerun_release *args:
	./target/release/{{main_name}} {{args}}

# run the example single-condition generator program (single-file, built with -file). NOT a CLI
# consumer: it hardcodes one predicate and calls norn.generate_accepted directly, so it takes no
# --scenario/--count flags - edit the source to change what it generates.
example *args: mktarget_dirs
	odin run examples/strong-1c.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:target/debug/strong-1c.exe {{args}}

# run the multi-seat opener+responder example generator program (single-file, built with -file).
# Like `example`, it bypasses the CLI framework entirely (hardcoded predicate, no flags).
example2 *args: mktarget_dirs
	odin run examples/1major-gf-support.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:target/debug/1major-gf.exe {{args}}

# run the scan-vs-bitmask-index hand-evaluation benchmark (release, optimised)
bench *args: mktarget_dirs
	odin run cmd/bench.odin -file -o:speed -microarch:native -linker:{{linker}} -out:target/release/bench.exe {{args}}

# run all tests in every package that has them
test *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -linker:{{linker}} -out:target/debug/test-norn.exe {{args}}
	odin test cli -debug -file -microarch:native -show-timings -linker:{{linker}} -out:target/debug/test-cli.exe {{args}}
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:target/debug/test-combo.exe {{args}}

# run only the card-combination analyser's tests (the `combo` package)
test-combo *args: mktarget_dirs
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:target/debug/test-combo.exe {{args}}

# run one named test in the library package (where most unit tests live)
test1 name *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -test-name:{{name}} -linker:{{linker}} -out:target/debug/{{test_main_name}} {{args}}

# simple delete of all debug databases and executables in the target directory
clean:
	rm -rf target
	just mktarget_dirs

# build the CLI with some verbose diagnostics
diagnose *args: mktarget_dirs
	odin build {{cli_pkg}} -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -linker:{{linker}} -out:target/debug/{{main_name}} {{args}}
