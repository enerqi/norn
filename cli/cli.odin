package cli

/*
	cli.odin — command-line parsing.

	`parse_args` turns the raw argument list into an `Options` struct. It is deliberately PURE: it
	does no I/O, never exits the process, and reports problems by returning `ok = false` and a
	message. That keeps every branch unit-testable. The app layer (app.odin) is what prints usage,
	writes errors, and sets exit codes.

	Supported flags (GNU-ish; both `--flag value` and `--flag=value` work):

		-n, --count    N           number of deals to generate (default 1)
		-f, --format   FORMAT      output format: line|pretty|handviewer|html-handviewer|html-cards|pbn|numeric (default line)
		-o, --output   PATH        output file, or "-" for stdout (default "-")
		-s, --seed     N           PRNG seed for reproducible deals (default: a fresh seed each run)
		-S, --scenario NAME        keep only deals matching a named scenario
		    --predeal      SPEC    fix cards to seats before dealing, e.g. "N:AS,KS S:QH"
		    --smartstack   SPEC    bias one seat to a shape-set + hcp window, e.g. "N 20-21 balanced"
		    --frequency    N       measure each scenario's acceptance rate over N deals (no deals emitted)
		    --list                 list the available scenarios
		-h, --help                 show usage

	WHY THIS IS HAND-WRITTEN AND NOT `core:flags`
	---------------------------------------------
	`core:flags` (struct tags + RTTI, with generated usage) is the right default for a program whose
	flags are a flat bag of scalars — the odin-sims consumer `analyse_deal.odin` was converted to it and
	came out shorter, with usage text that cannot drift. It was weighed for this parser too and
	rejected, for four reasons specific to THIS command line:

	  1. No flag ALIASES. `core:flags` takes one name per struct field (`args:"name=..."`), but half the
	     flags above carry a short form (`-n`/`--count`, `-S`/`--scenario`, ...) plus two long synonyms
	     (`--freq`, `--stack`). Each alias would need a shadow field marked `args:"hidden"` and a merge
	     pass — more lines than the `switch` case it replaces.
	  2. Enum values are matched by their EXACT Odin name (`reflect.enum_from_name_any`), so a
	     `norn.Output_Format` field would demand `--format Html_Cards`. `parse_format` below is
	     case-insensitive and accepts `hv`/`bbo`/`cards`/`num`; keeping that means keeping `format` a
	     string and parsing it here anyway — `core:flags` would do nothing for that flag.
	  3. `Mode` is a union and `core:flags` can only fill a flat struct. The mutually-exclusive actions
	     would arrive as the bag of booleans the `Mode` comment below deliberately rejects, and would
	     then need re-deriving into the union — a mapping layer, not a saving.
	  4. `register_type_setter` (the hook that would parse `--predeal` / `--smartstack` into their norn
	     types) is a package-level GLOBAL. `cli` is a LIBRARY: every consumer linking it would share and
	     fight over that one setter. Consumers must take such flags as strings and post-parse them —
	     which is what `parse_predeal` / `parse_smartstack` already do.

	What `core:flags` would genuinely buy — generated usage, and errors written for you — is already
	covered here: app.odin owns the usage text, and this proc's `ok`/`message` contract is what keeps it
	pure and exhaustively unit-testable in cli_test.odin. Revisit if `core:flags` grows alias support.
*/

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../norn"

// What this invocation DOES. The four non-default actions are mutually exclusive and each carries
// only its own data, so they are variants rather than a bag of booleans with fields that matter for
// exactly one of them (a `trials` that means nothing unless `frequency`, an `html_dir` that means
// nothing unless exporting). `main_program` switches on this once; nothing downstream re-derives it.
Mode :: union {
	Generate,
	Export_Html,
	Measure_Frequency,
	List_Scenarios,
	Show_Usage,
}

// The default: emit `count` deals in `format` to `output`, optionally filtered by `scenario`.
Generate :: struct {}

// `--html-dir DIR`: batch-export scenarios to `<dir>/<name>.html` and exit (the equivalent of the
// regen-html-deals.py helper). Ignores --output. By default every scenario is exported; --scenario
// narrows it to a comma-separated subset.
Export_Html :: struct {
	dir: string,
}

// `--frequency N`: emit no deals; instead measure each selected scenario's acceptance rate over
// `trials` random deals, one line per scenario. --scenario narrows the selection as with --html-dir.
Measure_Frequency :: struct {
	trials: int,
}

// `--list`: print the scenario catalogue and exit.
List_Scenarios :: struct {}

// `--help`: print usage and exit.
Show_Usage :: struct {}

// Parsed program options: the settings common to every mode, plus the `mode` that says what to do
// with them.
Options :: struct {
	mode:            Mode,
	count:           int,
	format:          norn.Output_Format,
	output:          string,
	// The PRNG seed, or nil for "pick a fresh one and report it". A plain `u64` cannot express that
	// distinction — 0 is a perfectly valid seed.
	seed:            Maybe(u64),
	// When non-empty, only deals satisfying the named scenario's condition are kept (reject
	// sampling). Empty means the default "accept every deal" behaviour. In the batch modes it is
	// instead a comma-separated subset of the registry.
	scenario:        string,
	// For the handviewer/html formats: randomise each deal's vulnerability and dealer (the default,
	// for practice variety). `--fixed-table` clears this for deterministic output.
	randomize_table: bool,
	// Cards fixed to seats before dealing (set by --predeal); nil means a fully random deal. Applies
	// to every generation path (plain, html export, frequency).
	predeal:         Maybe(norn.Predeal),
	// One seat biased to a shape-set + hcp window (set by --smartstack); nil means ordinary dealing.
	// Mutually exclusive with --predeal (it already lays out a whole seat). Applies to every
	// generation path. Big by value, but Options is not copied on a hot path.
	smartstack:      Maybe(norn.Smart_Stack),
	// When true (--dd), the consumer's double-dummy hooks are enabled. parse_args only sets the flag;
	// the hooks themselves come from code (main_program wires them from its Gen_Hooks argument), so
	// this package stays solver-agnostic. Off by default: the base generator never calls a solver.
	dd:              bool,
	// Consumer-supplied generation hooks, wired in by main_program when `dd` is set (never by
	// parse_args — they are function values, not command-line data). Empty/nil unless --dd was passed.
	//
	// Both maps are keyed by scenario name, so each scenario carries its OWN double-dummy hooks (a
	// preempt defence and a slam scenario want different tests / captions); a scenario absent from a
	// map gets that hook as nil. Keeping annotators per-scenario (rather than one global annotator) is
	// what lets the batch export pool the scenarios that touch no solver — see `export_uses_dd`.
	dd_filters:      map[string]norn.Deal_Filter,
	dd_annotators:   map[string]norn.Deal_Annotator,
}

// The defaults applied before any flags are read.
default_options :: proc() -> Options {
	return Options {
		mode = Generate{},
		count = 1,
		format = .Line,
		output = "-",
		seed = nil,
		scenario = "",
		randomize_table = true,
		predeal = nil,
		smartstack = nil,
		dd = false,
	}
}

// Parse `args` (the argument list WITHOUT the program name). On success returns the options and
// `ok = true`; on a usage error returns `ok = false` and a human-readable `message`. `--help` and
// `--list` return immediately with `ok = true` and their own `mode`, for the caller to act on.
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
			opts.mode = Show_Usage{}
			return opts, true, ""

		case "--list":
			opts.mode = List_Scenarios{}
			return opts, true, ""

		case "--fixed-table":
			opts.randomize_table = false

		case "--dd":
			opts.dd = true

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
			opts.mode = Export_Html {
				dir = value,
			}

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
			opts.mode = Measure_Frequency {
				trials = n,
			}

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
					"invalid value for %s: %q (expected line, pretty, handviewer, html-handviewer, html-cards, pbn or numeric)",
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
	case strings.equal_fold(name, "html-handviewer"),
	     strings.equal_fold(name, "html-bbo"),
	     strings.equal_fold(name, "bbo"),
	     strings.equal_fold(name, "html"):
		return .Html_Handviewer, true
	case strings.equal_fold(name, "html-cards"), strings.equal_fold(name, "cards"):
		return .Html_Cards, true
	case strings.equal_fold(name, "pbn"):
		return .Pbn, true
	case strings.equal_fold(name, "numeric"), strings.equal_fold(name, "num"):
		return .Numeric, true
	}
	return .Line, false
}
