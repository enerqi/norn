# `cmd.exe` starts in ~9ms and always available. just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: it is a poor language for a multi-line recipe, hence uv -> python preferred for more complex tasks
[windows]
set shell := ["cmd.exe", "/c"]
[unix]
set shell := ["bash", "-c"]
set minimum-version := "1.49.0"  # user-defined functions (1.49)
set unstable  # user-defined functions
set lazy
# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x)
# uv resolves/downloads on every platform and --no-project means no looking for pyproject.toml / local .venv
# just recipes opt in with the bare `[script]` attribute (no interpreter argument)
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

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
# path in *command* position ("'target' is not recognized") even quoted.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to. `-linker:` takes exactly four values: `default` (Odin
# picks - MSVC `link.exe` on Windows), `lld`, `radlink` (Windows only, bundled with Odin, hence the
# Windows default here) and `mold` (Linux only, not bundled). Odin has no build cache and relinks on
# every build, so this is a per-iteration cost.
#
# Override for one command without editing this file - for `-lto`, which on Windows *requires* lld, or
# for a machine that has mold when the project default does not assume it:
#
#     ODIN_LINKER=lld just test -lto:thin
#
# An env var rather than a recipe argument because `odin` errors on a repeated flag ("Previous flag set:
# 'linker'"), so a `-linker:` passed through a recipe's `*args` would collide with the one added below.
# Which value to pick, and the lld-on-macOS caveats: the odin-lang-skeleton README, "Choosing a linker".
linker := env_var_or_default("ODIN_LINKER", if os() == "windows" { "radlink" } else { "default" })

import '.just/toolchain.just'
# Optional feature files land in the same recipe namespace; drop one in and it appears in `just --list`.
# import? 'bench/bench.just'

# Here, not in .just/toolchain.just - what gets formatted is a project decision
# `{{odinfmt_bin}}`, never a bare `odinfmt` - pins the binary for project consistency
# ---
# odinfmt every .odin file under this directory (odinfmt walks subdirs itself)
[group('qa')]
format: ensure-odinfmt
	"{{odinfmt_bin}}" -w .

# `-vet-tabs` is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; not implied
# by `-strict-style`. Library packages need `-no-entry-point`; the single-file programs do not.
# Accepts extra args like `-show-timings` as needed.
# ---
# type check + vet + strict style across all packages
[group('qa')]
lint *args:
	odin check norn -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check cli -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check combo -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}
	odin check {{cli_pkg}} -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check cmd/bench.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check examples/strong-1c.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}
	odin check examples/1major-gf-support.odin -file -vet -vet-cast -strict-style -vet-tabs {{args}}

# The fast "does it still compile" loop: deliberately without `lint`'s vet and style flags, which are
# worth a separate, slower pass rather than noise between an edit and knowing whether it type checks.
# ---
# type check the library packages only, no vet or style pass
[group('qa')]
check *args:
	odin check norn -no-entry-point {{args}}
	odin check cli -no-entry-point {{args}}
	odin check combo -no-entry-point {{args}}


# Every recipe that produces a binary depends on this. Odin does not create the out directory (the
# linker fails with LNK1104). The dirs are made in one line because just starts a shell per recipe line
# and on Windows the shell launch dwarfs the work.
# ---
# ensure the build artifacts top level directory exists
[group('housekeeping')]
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop var is a single `%d`, NOT the `%%d` that a .bat file would use for escaping
# ---
# ensure the build artifacts top level directory exists
[group('housekeeping')]
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# `--` separates the program's args from odin's own flags. `-debug` implies `-o:none`, so this is the
# fastest to compile and the friendliest to step through. (-keep-executable so `rerun_debug` skips the
# recompile.) Nil registry: generator flags only (see the header note).
# ---
# run the CLI, generator flags only - no scenarios in this build (debug build)
[group('build')]
run_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("debug", main_name) }} -- {{args}}

alias run := run_debug

# `-o:minimal` is one rung above the `-debug` default of `-o:none`: still quick to compile and mostly
# faithful to step through, but noticeably faster at runtime.
# ---
# run the CLI with debug info and light optimizations
[group('build')]
run_fast_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:minimal -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("fast_debug", main_name) }} -- {{args}}

# Release codegen with debug info retained: for profiling and for chasing bugs that only appear under
# optimization. Slowest to compile, and the debugger will jump around inlined/reordered code.
# ---
# run the CLI with full optimizations AND debug info
[group('build')]
run_release_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release_debug", main_name) }} -- {{args}}

# run the CLI with optimizations (-keep-executable so `rerun_release` can skip recompiling)
[group('build')]
run_release *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release", main_name) }} -- {{args}}

# `run_release` plus every runtime safety check compiled out: `-no-bounds-check` (slice/array indexing),
# `-disable-assert` (the built-in `assert`) and `-no-type-assert` (union/any type assertions). Those
# checks are what turn a memory-corrupting bug into a clean panic, so a fault here is undefined
# behaviour rather than a readable message - benchmark against `run_release` before adopting it, and
# keep a checked build in your test matrix.
# ---
# run the CLI with optimizations and ALL runtime safety checks removed
[group('build')]
run_release_nochecks *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -no-bounds-check -disable-assert -no-type-assert -microarch:native -show-timings -keep-executable -linker:{{linker}} -out:{{ target_path("release_nochecks", main_name) }} -- {{args}}

# KIND is `address` (default, ASan), `memory` or `thread`; only `address` is widely supported - `memory`
# and `thread` need a clang-ish toolchain (not Windows/MSVC). ON WINDOWS `address` CATCHES STACK ERRORS
# BUT NOT HEAP ERRORS: Odin allocates through `HeapAlloc`, which ASan does not intercept, so a clean run
# there says nothing about your heap.
#
# Both sanitizer recipes deliberately omit `-linker:{{linker}}` - do not "fix" the inconsistency. A
# sanitizer has to interpose on the runtime and not every linker cooperates: `radlink` (this file's
# Windows default, bundled with Odin, so it is what you get by accident) links an ASan binary that dies
# on startup with a bare `0xc000001d` illegal-instruction exception and no usable stack, while
# `-linker:default` runs it. Link speed is worth nothing on a diagnostic run anyway.
#
# Usage:  just sanitize   or   just sanitize thread -- --count 4
# ---
# run the CLI under a sanitizer (address | memory | thread)
[group('test')]
sanitize kind="address" *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{main_name}}") }} -- {{args}}

# See `sanitize` above for platform support, the Windows heap caveat and why no linker is pinned.
# ---
# run the library tests under a sanitizer (address | memory | thread)
[group('test')]
test_sanitize kind="address" *args: mktarget_dirs
	odin test norn -debug -file -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{test_main_name}}") }} {{args}}

# Odin has no build cache, so a plain `run` always rebuilds. Requires a prior `run_debug`/`run` build.
# ---
# re-execute the already-built debug binary WITHOUT recompiling
[group('build')]
rerun_debug *args:
	{{ target_path("debug", main_name) }} {{args}}

alias rerun := rerun_debug

# re-run the last fast_debug binary without recompiling. Requires a prior `run_fast_debug` build.
[group('build')]
rerun_fast_debug *args:
	{{ target_path("fast_debug", main_name) }} {{args}}

# re-run the last release_debug binary without recompiling. Requires a prior `run_release_debug` build.
[group('build')]
rerun_release_debug *args:
	{{ target_path("release_debug", main_name) }} {{args}}

# re-run the last release binary without recompiling. Requires a prior `run_release` build.
[group('build')]
rerun_release *args:
	{{ target_path("release", main_name) }} {{args}}

# re-run the last nochecks binary without recompiling. Requires a prior `run_release_nochecks` build.
[group('build')]
rerun_release_nochecks *args:
	{{ target_path("release_nochecks", main_name) }} {{args}}

# hyperfine (https://github.com/sharkdp/hyperfine) times whole *processes*, and is installed separately.
# Over `rerun_release`'s binary rather than `just run_release`: Odin has no build cache, so timing the
# recipe would mostly time the compiler - build first. `-N` skips the shell hyperfine would otherwise
# spawn per run, at the cost that hyperfine splits the command itself: no pipes, redirects or quoted
# arguments containing spaces. For per-procedure numbers use `just bench`.
#
# `replace` back to forward slashes, unlike every other use of `target_path` here. Under `-N` the command
# is parsed by hyperfine, whose splitter treats `\` as an escape, so a Windows path arrives as
# `targetreleasenorn.exe` and fails with a bare "program not found". Recipes that put the path in
# *command* position keep the native separators, because that is the case cmd.exe rejects a slash in.
#
# Usage:  just time_release --count 100
# ---
# time the release CLI end to end with hyperfine (needs a prior run_release)
[group('perf')]
time_release *args:
	hyperfine -N --warmup 3 "{{ replace(target_path("release", main_name), "\\", "/") }} {{args}}"

# A/B two build profiles in one run - hyperfine prints the ratio between them, which is the number worth
# knowing about `-no-bounds-check`. Times both binaries, so needs a prior `run_release` AND
# `run_release_nochecks`. Forward slashes for the same reason as `time_release` above.
# ---
# compare the release and nochecks CLI binaries with hyperfine
[group('perf')]
time_profiles *args:
	hyperfine -N --warmup 3 "{{ replace(target_path("release", main_name), "\\", "/") }} {{args}}" "{{ replace(target_path("release_nochecks", main_name), "\\", "/") }} {{args}}"

# NOT a CLI consumer: it hardcodes one predicate and calls norn.generate_accepted directly, so it takes
# no --scenario/--count flags - edit the source to change what it generates.
# ---
# run the example single-condition generator program (single-file, built with -file)
[group('docs')]
example *args: mktarget_dirs
	odin run examples/strong-1c.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:{{ target_path("debug", "strong-1c.exe") }} {{args}}

# Like `example`, it bypasses the CLI framework entirely (hardcoded predicate, no flags).
# ---
# run the multi-seat opener+responder example generator program (single-file, built with -file)
[group('docs')]
example2 *args: mktarget_dirs
	odin run examples/1major-gf-support.odin -file -o:speed -show-timings -microarch:native -linker:{{linker}} -out:{{ target_path("debug", "1major-gf.exe") }} {{args}}

# An example is documentation, and documentation stops being true the moment the API moves under it. This
# is the cheap guard against that. `-file` is not optional: without it odin reads examples/ as one
# package and the several `main` procedures collide. A `[script]` because just has no loop and cmd.exe is
# a poor place for one.
# ---
# type check every example in examples/
[group('docs')]
[script]
examples-check:
	import glob, subprocess, sys

	files = sorted(glob.glob("examples/*.odin"))
	if not files:
		sys.exit("no examples found in examples/")

	for path in files:
		# flush=True because python fully buffers stdout when it is a pipe (CI logs, `just examples-check > f`),
		# which would land these lines after the compiler's stderr and lose which example broke.
		print("checking " + path, flush=True)
		result = subprocess.run(
			["odin", "check", path, "-file", "-vet", "-vet-cast", "-strict-style", "-vet-tabs"]
		)
		if result.returncode != 0:
			sys.exit(result.returncode)
	print("checked " + str(len(files)) + " example(s)")

# Writes to stdout; redirect it to keep a copy. Deliberately NOT `-all-packages`, which documents every
# package the project *uses* - all of `core:` included - rather than this one.
# ---
# print the norn library's documentation
[group('docs')]
doc *args:
	odin doc norn {{args}}

# run the scan-vs-bitmask-index hand-evaluation benchmark (release, optimised)
[group('perf')]
bench *args: mktarget_dirs
	odin run cmd/bench.odin -file -o:speed -microarch:native -linker:{{linker}} -out:{{ target_path("release", "bench.exe") }} {{args}}

# run all tests in every package that has them
[group('test')]
test *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-norn.exe") }} {{args}}
	odin test cli -debug -file -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-cli.exe") }} {{args}}
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-combo.exe") }} {{args}}

# run only the card-combination analyser's tests (the `combo` package)
[group('test')]
test-combo *args: mktarget_dirs
	odin test combo -debug -microarch:native -show-timings -linker:{{linker}} -out:{{ target_path("debug", "test-combo.exe") }} {{args}}

# Filtering is a `core:testing` define, not a compiler flag - there is no `-test-name:`, and a stale
# spelling of one fails with `Unknown flag: 'test-name'` before anything builds. NAME takes a
# comma-separated list and the package prefix is optional, so `norn.my_test`, `my_test` and `one,two`
# all work:
#     just test1 my_test
# ---
# run one named test in the library package (comma-separated for several)
[group('test')]
test1 name *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# simple delete of all debug databases and executables in the target directory
[group('housekeeping')]
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# cmd's `rm -rf` is `rmdir /s /q`. Guarded by `if exist` because rmdir exits non-zero on a missing path,
# which would fail the recipe on an already-clean tree.
# ---
# simple delete of all debug databases and executables in the target directory
[group('housekeeping')]
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs

# build the CLI with some verbose diagnostics
[group('build')]
diagnose *args: mktarget_dirs
	odin build {{cli_pkg}} -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -linker:{{linker}} -out:{{ target_path("debug", main_name) }} {{args}}
