set windows-shell := ["nu", "-c"]
set shell := ["bash", "-c"]
set unstable  # [script("python")] feature - https://github.com/casey/just/issues/1479

# The CLI binary is a single-file program (cmd/norn.odin, built with -file); the library lives in
# the norn package. The `-file` is baked in here so every recipe that builds it stays in sync.
cli_pkg := "cmd/norn.odin -file"
main_name := "norn.exe"
test_main_name := "test-main.exe"

# odinfmt every .odin file under this directory (odinfmt walks subdirs itself)
format:
	odinfmt -w .


# lint checks for style and potential bugs across every package. Accepts extra args like
# `--show-timings` as needed. Library packages need -no-entry-point; the program packages do not.
# ---
# type check + vet + strict style across all packages
lint *args:
	odin check norn -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check cli -vet -vet-cast -strict-style -no-entry-point {{args}}
	odin check {{cli_pkg}} -vet -vet-cast -strict-style {{args}}
	odin check cmd/bench.odin -file -vet -vet-cast -strict-style {{args}}
	odin check examples/strong-1c.odin -file -vet -vet-cast -strict-style {{args}}
	odin check examples/1major-gf-support.odin -file -vet -vet-cast -strict-style {{args}}


# ensure the build artifacts top level directory exists
[unix]
@mktarget_dirs:
	-mkdir -p target
	-mkdir -p target/debug
	-mkdir -p target/fastdebug
	-mkdir -p target/release

# ensure the build artifacts top level directory exists
[windows]
@mktarget_dirs:
	-mkdir target
	-mkdir target/debug
	-mkdir target/fastdebug
	-mkdir target/release

# run the CLI with a debug build. `--` separates the program's args from odin's own flags.
# `-keep-executable` leaves the built binary in place (odin run deletes it by default) so `rerun_debug`
# can execute it again without recompiling.
# ---
# run the CLI (debug build)
run_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -microarch:native -show-timings -keep-executable -out:target/debug/{{main_name}} -- {{args}}

alias run := run_debug

# run the CLI with debug and optimizations
run_fastdebug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:speed -microarch:native -show-timings -keep-executable -out:target/fastdebug/{{main_name}} -- {{args}}

# run the CLI with optimizations
run_release *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -microarch:native -show-timings -keep-executable -out:target/release/{{main_name}} -- {{args}}

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

# run the example single-condition generator program (single-file, built with -file)
example *args: mktarget_dirs
	odin run examples/strong-1c.odin -file -o:speed -show-timings -microarch:native -out:target/debug/strong-1c.exe {{args}}

# run the multi-seat opener+responder example generator program (single-file, built with -file)
example2 *args: mktarget_dirs
	odin run examples/1major-gf-support.odin -file -o:speed -show-timings -microarch:native -out:target/debug/1major-gf.exe {{args}}

# run the scan-vs-bitmask-index hand-evaluation benchmark (release, optimised)
bench *args: mktarget_dirs
	odin run cmd/bench.odin -file -o:speed -microarch:native -out:target/release/bench.exe {{args}}

# run all tests in every package that has them
test *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -out:target/debug/test-norn.exe {{args}}
	odin test cli -debug -file -microarch:native -show-timings -out:target/debug/test-cli.exe {{args}}

# run one named test in the library package (where most unit tests live)
test1 name *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -test-name:{{name}} -out:target/debug/{{test_main_name}} {{args}}

# simple delete of all debug databases and executables in the target directory
clean:
	rm -rf target
	just mktarget_dirs

# build the CLI with some verbose diagnostics
diagnose *args: mktarget_dirs
	odin build {{cli_pkg}} -debug -microarch:native -show-more-timings -show-debug-messages -show-timings -out:target/debug/{{main_name}} {{args}}
