package cli

/*
	app.odin — the reusable CLI entry point.

	`main_program(registry)` turns command-line arguments into actions and returns an exit code. A
	consumer's `main` does its operational setup (logging, allocators, profiling) and then calls this
	with its scenario registry — keeping the program-specific shell separate from the generic driver.

	It RETURNS the exit code rather than calling `os.exit`, so the caller's deferred operational
	teardown runs before the process terminates.
*/

import "core:fmt"
import "core:os"

// Exit codes. 0 = success; 2 for a usage/CLI error and 1 for a runtime failure.
EXIT_OK :: 0
EXIT_RUNTIME_ERROR :: 1
EXIT_USAGE_ERROR :: 2

// Parse arguments and run against `registry`. Kept thin: parse -> (usage / list) -> generate -> map
// outcomes to an exit code.
main_program :: proc(registry: []Scenario) -> int {
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

	if opts.list {
		write_scenario_list(os.stdout, registry)
		return EXIT_OK
	}

	if opts.frequency {
		if measured, measure_message := measure_frequencies(registry, opts); !measured {
			fmt.eprintfln("norn: %s", measure_message)
			return EXIT_RUNTIME_ERROR
		}
		return EXIT_OK
	}

	if opts.html_dir != "" {
		if exported, export_message := export_all_html(registry, opts); !exported {
			fmt.eprintfln("norn: %s", export_message)
			return EXIT_RUNTIME_ERROR
		}
		return EXIT_OK
	}

	if generated, gen_message := run(registry, opts); !generated {
		fmt.eprintfln("norn: %s", gen_message)
		return EXIT_RUNTIME_ERROR
	}

	return EXIT_OK
}

// Print the usage/help text to the given file (stdout for --help, stderr on a usage error).
write_usage :: proc(handle: ^os.File) {
	usage := `norn - a fast bridge deal generator

Usage:
  norn [options]

Options:
  -n, --count    N            number of deals to generate (default 1)
  -f, --format   FORMAT       output format: line|pretty|handviewer|html|pbn|numeric (default line)
  -o, --output   PATH         output file, or "-" for stdout (default "-")
  -s, --seed     N            PRNG seed for reproducible deals (default: fresh each run)
  -S, --scenario NAME[,...]   keep only deals matching the named scenario(s); with --html-dir, a
                              comma-separated subset to export
      --predeal    SPEC       fix cards to seats before dealing, e.g. "N:AS,KS S:QH" (rank+suit
                              labels: AS=ace spades, TH=ten hearts, 2C=two clubs)
      --smartstack SPEC       bias one seat to a shape-set + hcp window: "SEAT HCP SHAPE[/SHAPE...]",
                              e.g. "N 20-21 balanced", "S 10-13 6+,x,x,x". HCP: lo-hi | N | N+ | N-.
                              SHAPE: keyword (balanced|semibalanced|any) or S,H,D,C length fields
                              (N | N+ | N- | x). Builds the rare seat directly; can't combine with
                              --predeal
      --list                  list the available scenarios and exit
      --html-dir DIR          export scenarios to DIR/<name>.html and exit (all, or the --scenario subset)
      --frequency N           measure each scenario's acceptance rate over N deals and exit (no deals
                              emitted); all scenarios, or the --scenario subset
      --fixed-table           handviewer/html: fix vulnerability & dealer (default: randomise them)
  -h, --help                  show this help

Examples:
  norn --count 48
  norn -n 1000 -o deals.txt
  norn --count 12 --format pretty
  norn --count 24 --seed 1234              # reproducible
  norn -n 12 --predeal "N:AS,KS,QS"        # North always holds the top 3 spades
  norn -n 12 --smartstack "N 20-21 balanced" # North: balanced 20-21 hcp, built directly
  norn -n 12 --smartstack "S 10-13 6+,x,x,x" # South: 6+ spades, 10-13 hcp
  norn --scenario 1c-any -n 12 -f pretty   # 12 deals where North opens 1C
  norn -S 2c-opener -f handviewer          # BBO handviewer query strings
  norn -S 2c-opener -n 24 -f html -o x.html# one scenario as an HTML page
  norn --html-dir ./deals -n 48            # every scenario -> ./deals/<name>.html
  norn --html-dir ./deals -S 1c-any,2c-opener # just those two -> ./deals/<name>.html
  norn --frequency 1000000                 # acceptance rate of every scenario over 1M deals
  norn --frequency 1000000 -S 2c-opener    # just one scenario's rate over 1M deals
  norn --list                              # show all scenarios
`
	os.write_string(handle, usage)
}

// Print the scenario catalogue (name + description) from `registry`, one per line, aligned.
write_scenario_list :: proc(handle: ^os.File, registry: []Scenario) {
	width := 0
	for s in registry {
		if len(s.name) > width {
			width = len(s.name)
		}
	}
	for s in registry {
		fmt.fprintfln(handle, "  %-*s  %s", width, s.name, s.description)
	}
}
