package cli

/*
	cli_test.odin — unit tests for command-line parsing.

	parse_args is pure, so every branch can be checked directly with no process side effects.
*/

import "core:strings"
import "core:testing"

import "../norn"

// With no arguments, the documented defaults apply.
@(test)
test_parse_defaults :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({})
	testing.expect(t, ok, "empty args should parse")
	testing.expect_value(t, opts.count, 1)
	testing.expect_value(t, opts.format, norn.Output_Format.Line)
	testing.expect_value(t, opts.output, "-")
	testing.expect_value(t, opts.has_seed, false)
	testing.expect_value(t, opts.help, false)
	testing.expect_value(t, opts.scenario, "")
	testing.expect_value(t, opts.list, false)
	testing.expect_value(t, opts.html_dir, "")
	// Random table is the default; --fixed-table opts out.
	testing.expect_value(t, opts.randomize_table, true)
}

// --fixed-table clears the (default-on) randomize_table flag.
@(test)
test_parse_fixed_table :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"--fixed-table"})
	testing.expect(t, ok, "--fixed-table should parse")
	testing.expect_value(t, opts.randomize_table, false)
}

// Count accepts long, short, and `=` forms.
@(test)
test_parse_count_forms :: proc(t: ^testing.T) {
	for args in ([][]string{{"--count", "48"}, {"-n", "48"}, {"--count=48"}}) {
		opts, ok, msg := parse_args(args)
		testing.expectf(t, ok, "args %v should parse: %s", args, msg)
		testing.expect_value(t, opts.count, 48)
	}
}

// A non-numeric or negative count is a usage error.
@(test)
test_parse_count_errors :: proc(t: ^testing.T) {
	_, ok1, _ := parse_args({"--count", "abc"})
	testing.expect(t, !ok1, "non-numeric count should fail")

	_, ok2, _ := parse_args({"--count", "-5"})
	testing.expect(t, !ok2, "negative count should fail")
}

// Format names are case-insensitive and map to the right enum value; unknown names fail.
@(test)
test_parse_format :: proc(t: ^testing.T) {
	opts_line, ok_line, _ := parse_args({"--format", "LINE"})
	testing.expect(t, ok_line, "LINE should parse")
	testing.expect_value(t, opts_line.format, norn.Output_Format.Line)

	opts_pretty, ok_pretty, _ := parse_args({"-f", "pretty"})
	testing.expect(t, ok_pretty, "pretty should parse")
	testing.expect_value(t, opts_pretty.format, norn.Output_Format.Pretty)

	opts_hv, ok_hv, _ := parse_args({"--format", "handviewer"})
	testing.expect(t, ok_hv, "handviewer should parse")
	testing.expect_value(t, opts_hv.format, norn.Output_Format.Handviewer)

	opts_hv2, ok_hv2, _ := parse_args({"-f", "HV"})
	testing.expect(t, ok_hv2, "hv alias should parse")
	testing.expect_value(t, opts_hv2.format, norn.Output_Format.Handviewer)

	opts_html, ok_html, _ := parse_args({"--format", "html"})
	testing.expect(t, ok_html, "html should parse")
	testing.expect_value(t, opts_html.format, norn.Output_Format.Html)

	_, ok_bad, _ := parse_args({"--format", "fancy"})
	testing.expect(t, !ok_bad, "unknown format should fail")
}

// --html-dir captures the directory.
@(test)
test_parse_html_dir :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"--html-dir", "out/deals"})
	testing.expect(t, ok, "--html-dir should parse")
	testing.expect_value(t, opts.html_dir, "out/deals")
}

// --frequency sets the mode flag and the trial count; a non-positive or non-numeric value fails.
@(test)
test_parse_frequency :: proc(t: ^testing.T) {
	for args in ([][]string{{"--frequency", "1000000"}, {"--freq", "1000000"}, {"--frequency=1000000"}}) {
		opts, ok, msg := parse_args(args)
		testing.expectf(t, ok, "args %v should parse: %s", args, msg)
		testing.expect_value(t, opts.frequency, true)
		testing.expect_value(t, opts.trials, 1_000_000)
	}

	_, ok_zero, _ := parse_args({"--frequency", "0"})
	testing.expect(t, !ok_zero, "zero trials should fail")

	_, ok_bad, _ := parse_args({"--frequency", "lots"})
	testing.expect(t, !ok_bad, "non-numeric trials should fail")
}

// select_scenarios: empty selector returns the whole registry; a named subset returns just those
// (in order); an unknown name is an error.
@(test)
test_select_scenarios :: proc(t: ^testing.T) {
	registry := []Scenario {
		{name = "a", predicate = norn.accept_all},
		{name = "b", predicate = norn.accept_all},
		{name = "c", predicate = norn.accept_all},
	}

	all, all_filter, all_ok, _ := select_scenarios(registry, "")
	defer delete(all_filter)
	testing.expect(t, all_ok, "empty selector should succeed")
	testing.expect_value(t, len(all), 3)

	subset, sub_filter, sub_ok, _ := select_scenarios(registry, "c, a")
	defer delete(sub_filter)
	testing.expect(t, sub_ok, "named subset should succeed")
	testing.expect_value(t, len(subset), 2)
	testing.expect_value(t, subset[0].name, "c")
	testing.expect_value(t, subset[1].name, "a")

	_, bad_filter, bad_ok, _ := select_scenarios(registry, "a,nope")
	defer delete(bad_filter)
	testing.expect(t, !bad_ok, "unknown name should fail")
}

// Output path is taken verbatim.
@(test)
test_parse_output :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"-o", "deals.txt"})
	testing.expect(t, ok, "output should parse")
	testing.expect_value(t, opts.output, "deals.txt")
}

// Seed sets both the value and the has_seed marker; a bad seed fails.
@(test)
test_parse_seed :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"--seed", "1234"})
	testing.expect(t, ok, "seed should parse")
	testing.expect_value(t, opts.seed, u64(1234))
	testing.expect_value(t, opts.has_seed, true)

	_, ok_bad, _ := parse_args({"--seed", "xyz"})
	testing.expect(t, !ok_bad, "non-numeric seed should fail")
}

// --help is reported via opts.help with ok = true.
@(test)
test_parse_help :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"--help"})
	testing.expect(t, ok, "--help should parse")
	testing.expect_value(t, opts.help, true)
}

// --scenario captures the name; --list sets the flag.
@(test)
test_parse_scenario_and_list :: proc(t: ^testing.T) {
	opts, ok, _ := parse_args({"--scenario", "1c-any"})
	testing.expect(t, ok, "--scenario should parse")
	testing.expect_value(t, opts.scenario, "1c-any")

	opts_short, ok_short, _ := parse_args({"-S", "1c-any"})
	testing.expect(t, ok_short, "-S should parse")
	testing.expect_value(t, opts_short.scenario, "1c-any")

	opts_list, ok_list, _ := parse_args({"--list"})
	testing.expect(t, ok_list, "--list should parse")
	testing.expect_value(t, opts_list.list, true)
}

// Unknown flags and value-less flags are usage errors with informative messages.
@(test)
test_parse_errors :: proc(t: ^testing.T) {
	_, ok_unknown, msg_unknown := parse_args({"--nope"})
	testing.expect(t, !ok_unknown, "unknown flag should fail")
	testing.expect(t, strings.contains(msg_unknown, "unknown option"), "message should name the problem")

	_, ok_missing, msg_missing := parse_args({"--count"})
	testing.expect(t, !ok_missing, "missing value should fail")
	testing.expect(t, strings.contains(msg_missing, "requires a value"), "message should explain the missing value")
}

// Multiple flags combine, and later flags override earlier ones.
@(test)
test_parse_combined :: proc(t: ^testing.T) {
	opts, ok, msg := parse_args({"-n", "10", "--format", "pretty", "-o", "out.txt", "--seed", "9"})
	testing.expectf(t, ok, "combined args should parse: %s", msg)
	testing.expect_value(t, opts.count, 10)
	testing.expect_value(t, opts.format, norn.Output_Format.Pretty)
	testing.expect_value(t, opts.output, "out.txt")
	testing.expect_value(t, opts.seed, u64(9))
}
