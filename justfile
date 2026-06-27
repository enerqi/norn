set windows-shell := ["nu", "-c"]
set shell := ["bash", "-c"]
set unstable  # [script("python")] feature - https://github.com/casey/just/issues/1479

# The CLI binary is built from the cmd/norn package; the library lives in the norn package.
cli_pkg := "cmd/norn"
main_name := "norn.exe"
test_main_name := "test-main.exe"

# odinfmt every odin file under this directory or subdirectories
[script("python")]
format:
	import os, subprocess
	for (root, _, files) in os.walk("."):
		for filename in files:
			if filename.endswith(".odin"):
				path = os.path.join(root, filename)
				subprocess.check_call(f"odinfmt -w {path}", shell=True)


# lint checks for style and potential bugs across every package. Accepts extra args like
# `--show-timings` as needed. Library packages need -no-entry-point; the program packages do not.
lint *args:
	odin check norn -vet -strict-style -no-entry-point {{args}}
	odin check conditions -vet -strict-style -no-entry-point {{args}}
	odin check {{cli_pkg}} -vet -strict-style {{args}}
	odin check examples/strong-1c -vet -strict-style {{args}}


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

# run the CLI with a debug build
run_debug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -microarch:native -show-timings -out:target/debug/{{main_name}} {{args}}

alias run := run_debug

# run the CLI with debug and optimizations
run_fastdebug *args: mktarget_dirs
	odin run {{cli_pkg}} -debug -o:speed -microarch:native -show-timings -out:target/fastdebug/{{main_name}} {{args}}

# run the CLI with optimizations
run_release *args: mktarget_dirs
	odin run {{cli_pkg}} -o:speed -microarch:native -show-timings -out:target/release/{{main_name}} {{args}}

# run the example single-condition generator program
example *args: mktarget_dirs
	odin run examples/strong-1c -debug -microarch:native -out:target/debug/strong-1c.exe {{args}}

# run all tests in every package that has them
test *args: mktarget_dirs
	odin test norn -debug -file -microarch:native -show-timings -out:target/debug/test-norn.exe {{args}}
	odin test conditions -debug -file -microarch:native -show-timings -out:target/debug/test-conditions.exe {{args}}
	odin test {{cli_pkg}} -debug -file -microarch:native -show-timings -out:target/debug/test-cli.exe {{args}}

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
