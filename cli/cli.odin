package cli

/*
	cli.odin — command-line parsing.

	`parse_args` turns the raw argument list into an `Options` struct. It is deliberately PURE: it
	does no I/O, never exits the process, and reports problems by returning `ok = false` and a
	message. That keeps every branch unit-testable. The app layer (app.odin) is what prints usage,
	writes errors, and sets exit codes.

	Supported flags (GNU-ish; both `--flag value` and `--flag=value` work):

		-n, --count    N           number of deals to generate (default 1)
		-f, --format   FORMAT      output format: line|pretty|handviewer|html|pbn|numeric (default line)
		-o, --output   PATH        output file, or "-" for stdout (default "-")
		-s, --seed     N           PRNG seed for reproducible deals (default: a fresh seed each run)
		-S, --scenario NAME        keep only deals matching a named scenario
		    --predeal      SPEC    fix cards to seats before dealing, e.g. "N:AS,KS S:QH"
		    --smartstack   SPEC    bias one seat to a shape-set + hcp window, e.g. "N 20-21 balanced"
		    --frequency    N       measure each scenario's acceptance rate over N deals (no deals emitted)
		    --list                 list the available scenarios
		-h, --help                 show usage
*/

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../norn"

// Parsed program options. `has_seed` distinguishes "user gave a seed" from "use a fresh one",
// which a plain `seed: u64` cannot express (0 is a perfectly valid seed).
Options :: struct {
	count:           int,
	format:          norn.Output_Format,
	output:          string,
	seed:            u64,
	has_seed:        bool,
	help:            bool,
	// When non-empty, only deals satisfying the named scenario's condition are kept (reject
	// sampling). Empty means the default "accept every deal" behaviour.
	scenario:        string,
	// `list` requests the catalogue of scenario names and exits without generating anything.
	list:            bool,
	// When non-empty, batch-export scenarios to `<html_dir>/<name>.html` and exit (the equivalent of
	// the regen-html-deals.py helper). Forces the html format and ignores --output. By default every
	// scenario is exported; if --scenario is also given it is treated as a comma-separated subset to
	// restrict the export to.
	html_dir:        string,
	// For the handviewer/html formats: randomise each deal's vulnerability and dealer (the default,
	// for practice variety). `--fixed-table` clears this for deterministic output.
	randomize_table: bool,
	// When true, no deals are emitted: instead each selected scenario's acceptance frequency is
	// measured over `trials` random deals and reported, one line per scenario. By default every
	// scenario is measured; --scenario restricts it to a comma-separated subset (as with --html-dir).
	frequency:       bool,
	// Number of deals to sample per scenario in frequency mode (set by --frequency N).
	trials:          int,
	// Cards fixed to seats before dealing (set by --predeal); nil means a fully random deal. Applies
	// to every generation path (plain, html export, frequency).
	predeal:         Maybe(norn.Predeal),
	// One seat biased to a shape-set + hcp window (set by --smartstack); nil means ordinary dealing.
	// Mutually exclusive with --predeal (it already lays out a whole seat). Applies to every
	// generation path. Big by value, but Options is not copied on a hot path.
	smartstack:      Maybe(norn.Smart_Stack),
}

// The defaults applied before any flags are read.
default_options :: proc() -> Options {
	return Options {
		count = 1,
		format = .Line,
		output = "-",
		seed = 0,
		has_seed = false,
		help = false,
		scenario = "",
		list = false,
		html_dir = "",
		randomize_table = true,
		frequency = false,
		trials = 0,
		predeal = nil,
		smartstack = nil,
	}
}

// Parse `args` (the argument list WITHOUT the program name). On success returns the options and
// `ok = true`; on a usage error returns `ok = false` and a human-readable `message`. Encountering
// `--help` returns `ok = true` with `opts.help = true` so the caller can show usage and stop.
parse_args :: proc(args: []string) -> (opts: Options, ok: bool, message: string) {
	opts = default_options()

	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1

		// Accept the `--flag=value` form by splitting on the first '='.
		flag := arg
		inline_value: string
		has_inline := false
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			flag = arg[:eq]
			inline_value = arg[eq + 1:]
			has_inline = true
		}

		switch flag {
		case "-h", "--help":
			opts.help = true
			return opts, true, ""

		case "--list":
			opts.list = true
			return opts, true, ""

		case "--fixed-table":
			opts.randomize_table = false

		case "-S", "--scenario":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			opts.scenario = value

		case "--html-dir":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			opts.html_dir = value

		case "--frequency", "--freq":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			n, parsed := strconv.parse_int(value)
			if !parsed {
				return opts, false, fmt.tprintf("invalid value for %s: %q is not an integer", flag, value)
			}
			if n <= 0 {
				return opts, false, fmt.tprintf("invalid value for %s: trials must be positive", flag)
			}
			opts.frequency = true
			opts.trials = n

		case "--predeal":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			pd, pd_ok, pd_why := parse_predeal(value)
			if !pd_ok {
				return opts, false, pd_why
			}
			opts.predeal = pd

		case "--smartstack", "--stack":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			ss, ss_ok, ss_why := parse_smartstack(value)
			if !ss_ok {
				return opts, false, ss_why
			}
			opts.smartstack = ss

		case "-n", "--count":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			n, parsed := strconv.parse_int(value)
			if !parsed {
				return opts, false, fmt.tprintf("invalid value for %s: %q is not an integer", flag, value)
			}
			if n < 0 {
				return opts, false, fmt.tprintf("invalid value for %s: count cannot be negative", flag)
			}
			opts.count = n

		case "-f", "--format":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			format, recognised := parse_format(value)
			if !recognised {
				return opts, false, fmt.tprintf(
					"invalid value for %s: %q (expected line, pretty, handviewer, html, pbn or numeric)",
					flag,
					value,
				)
			}
			opts.format = format

		case "-o", "--output":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			opts.output = value

		case "-s", "--seed":
			value, got, why := take_value(has_inline, inline_value, args, &i, flag)
			if !got {
				return opts, false, why
			}
			seed, parsed := strconv.parse_u64(value)
			if !parsed {
				return opts, false, fmt.tprintf("invalid value for %s: %q is not a non-negative integer", flag, value)
			}
			opts.seed = seed
			opts.has_seed = true

		case:
			return opts, false, fmt.tprintf("unknown option: %s", flag)
		}
	}

	if opts.predeal != nil && opts.smartstack != nil {
		return opts, false, "--predeal and --smartstack cannot be combined (smartstack already lays out a seat)"
	}

	return opts, true, ""
}

// Resolve the value for a flag: either the part after '=' (inline form) or the following argument,
// advancing `i` past it. Returns ok = false with a message if a value is required but missing.
take_value :: proc(
	has_inline: bool,
	inline_value: string,
	args: []string,
	i: ^int,
	flag: string,
) -> (
	value: string,
	ok: bool,
	message: string,
) {
	if has_inline {
		return inline_value, true, ""
	}
	if i^ < len(args) {
		value = args[i^]
		i^ += 1
		return value, true, ""
	}
	return "", false, fmt.tprintf("option %s requires a value", flag)
}

// Map a format name (case-insensitive) to its enum value.
parse_format :: proc(name: string) -> (format: norn.Output_Format, ok: bool) {
	switch {
	case strings.equal_fold(name, "line"):
		return .Line, true
	case strings.equal_fold(name, "pretty"):
		return .Pretty, true
	case strings.equal_fold(name, "handviewer"), strings.equal_fold(name, "hv"):
		return .Handviewer, true
	case strings.equal_fold(name, "html"):
		return .Html, true
	case strings.equal_fold(name, "pbn"):
		return .Pbn, true
	case strings.equal_fold(name, "numeric"), strings.equal_fold(name, "num"):
		return .Numeric, true
	}
	return .Line, false
}
