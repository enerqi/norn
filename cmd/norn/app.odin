package main

/*
	app.odin — the program's semantic entry point.

	`main.odin` handles operational setup (logging, allocators, profiling) and then calls
	`main_program`, which lives here. This is the layer that turns command-line arguments into
	actions and decides exit codes — the I/O shell around the pure core (cli, deal, export).
*/

import "core:fmt"
import "core:os"

// Exit codes. 0 = success; we follow the common convention of 2 for a usage/CLI error and 1 for a
// runtime failure.
EXIT_OK :: 0
EXIT_RUNTIME_ERROR :: 1
EXIT_USAGE_ERROR :: 2

// Parse arguments and run. Kept thin: parse -> (maybe show usage) -> generate -> map outcomes to an
// exit code.
//
// This RETURNS the exit code rather than calling `os.exit` itself. `os.exit` terminates immediately,
// skipping `main`'s deferred operational teardown (leak tracking, profiler flush, logger). By
// returning, we let `main` finish that cleanup and exit once, in one place.
main_program :: proc() -> int {
	opts, ok, message := parse_args(os.args[1:])

	if !ok {
		fmt.eprintfln("norn: %s", message)
		write_usage(os.stderr)
		return EXIT_USAGE_ERROR
	}

	if opts.help {
		write_usage(os.stdout)
		return EXIT_OK
	}

	if generated, gen_message := run(opts); !generated {
		fmt.eprintfln("norn: %s", gen_message)
		return EXIT_RUNTIME_ERROR
	}

	return EXIT_OK
}

// Print the usage/help text to the given file (stdout for --help, stderr on a usage error).
write_usage :: proc(handle: ^os.File) {
	usage := `norn — a fast bridge deal generator

Usage:
  norn [options]

Options:
  -n, --count   N            number of deals to generate (default 1)
  -f, --format  line|pretty  output format (default line)
  -o, --output  PATH         output file, or "-" for stdout (default "-")
  -s, --seed    N            PRNG seed for reproducible deals (default: fresh each run)
  -h, --help                 show this help

Examples:
  norn --count 48
  norn -n 1000 -o deals.txt
  norn --count 12 --format pretty
  norn --count 24 --seed 1234   # reproducible
`
	os.write_string(handle, usage)
}
