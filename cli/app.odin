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
import "core:strings"

import "../norn"

// Exit codes. 0 = success; 2 for a usage/CLI error and 1 for a runtime failure.
EXIT_OK :: 0
EXIT_RUNTIME_ERROR :: 1
EXIT_USAGE_ERROR :: 2

// Consumer-supplied generation hooks, injected via main_program. Engine-agnostic (see the
// `norn.Deal_Filter` / `norn.Deal_Annotator` docs) and optional; only wired into the run when the
// user passes --dd. A consumer that wants double-dummy filtering/annotation builds these over its
// solver of choice and hands them here, keeping this package solver-free.
//
// Both maps are keyed by scenario name, so a batch run gives each scenario its own double-dummy
// filter and/or annotator (or none). Per-scenario annotators (rather than one global one) let the
// export pool scenarios that touch no solver; annotate every scenario and they all naturally
// serialize (the solver isn't reentrant), each still parallel inside DDS.
Gen_Hooks :: struct {
	dd_filters:    map[string]norn.Deal_Filter,
	dd_annotators: map[string]norn.Deal_Annotator,
}

// Parse arguments and run against `registry`. Kept thin: parse -> (usage / list) -> generate -> map
// outcomes to an exit code. `hooks` carries the consumer's optional DD filter/annotator, applied
// only when --dd is passed.
main_program :: proc(registry: []Scenario, hooks := Gen_Hooks{}) -> int {
	opts, ok, message := parse_args(os.args[1:])

	if !ok {
		fmt.eprintfln("norn: %s", message)
		write_usage(os.stderr)
		return EXIT_USAGE_ERROR
	}

	// Wire the consumer's DD hooks into the options when --dd was requested. Behind the flag so the
	// default generator path never touches a solver.
	if opts.dd {
		opts.dd_filters = hooks.dd_filters
		opts.dd_annotators = hooks.dd_annotators
	}

	if opts.help {
		write_usage(os.stdout)
		return EXIT_OK
	}

	if opts.list {
		write_scenario_list(os.stdout, registry)
		return EXIT_OK
	}

	// Before doing any work, fail fast on a mistyped hook key — an unknown name would silently never
	// fire. (After --help/--list so those stay usable, but before every real action.)
	if hooks_ok, hooks_msg := validate_gen_hooks(registry, hooks); !hooks_ok {
		fmt.eprintfln("norn: %s", hooks_msg)
		return EXIT_USAGE_ERROR
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

// Fail fast on a mistyped hook key: every name in the DD hook maps must be a real scenario, else that
// hook silently never fires (a lookup by scenario name would just never match). Returns ok=false with
// a message listing the offenders. Runs regardless of --dd — a bad key is a program bug whether or
// not this invocation happens to use the hooks.
@(private)
validate_gen_hooks :: proc(registry: []Scenario, hooks: Gen_Hooks) -> (ok: bool, message: string) {
	unknown: [dynamic]string
	defer delete(unknown)
	for name in hooks.dd_filters {
		if _, found := lookup(registry, name); !found {
			append(&unknown, fmt.tprintf("dd_filter %q", name))
		}
	}
	for name in hooks.dd_annotators {
		if _, found := lookup(registry, name); !found {
			append(&unknown, fmt.tprintf("dd_annotator %q", name))
		}
	}
	if len(unknown) == 0 {
		return true, ""
	}
	return false, fmt.tprintf(
		"double-dummy hook(s) reference unknown scenario(s): %s (run --list for valid names)",
		strings.join(unknown[:], ", ", context.temp_allocator),
	)
}

// Print the usage/help text to the given file (stdout for --help, stderr on a usage error).
write_usage :: proc(handle: ^os.File) {
	usage := `norn - a fast bridge deal generator

Usage:
  norn [options]

Options:
  -n, --count    N            number of deals to generate (default 1)
  -f, --format   FORMAT       output format: line|pretty|handviewer|html-handviewer|html-cards|pbn|numeric
                              (default line). html-handviewer = BBO iframe page; html-cards =
                              self-rendered, offline card carousel
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
      --html-dir DIR          export scenarios to DIR/<name>.html and exit (all, or the --scenario
                              subset); BBO-iframe pages by default, or --format html-cards for the
                              offline card carousel
      --frequency N           measure each scenario's acceptance rate over N deals and exit (no deals
                              emitted); all scenarios, or the --scenario subset. With --dd the rate
                              also counts each scenario's double-dummy filter, matching what
                              generation keeps
      --fixed-table           handviewer/html formats: fix vulnerability & dealer (default: randomise)
      --dd                    enable the consumer's double-dummy hooks (per-scenario filter +
                              annotator); no effect unless the program supplies them. Applies to
                              generation, --html-dir export, AND --frequency (the filter is counted).
                              DD scenarios run serially (solver isn't reentrant); solver-free
                              scenarios still pool
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
  norn -S 2c-opener -n 24 -f html-handviewer -o x.html # one scenario as a BBO-iframe page
  norn -S 2c-opener -n 24 -f html-cards -o x.html      # ... as an offline card carousel
  norn --html-dir ./deals -n 48            # every scenario -> ./deals/<name>.html (BBO iframes)
  norn --html-dir ./deals -f html-cards -n 48 # ... as offline card carousels
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
