package main

/*
	cli_test.odin — unit tests for command-line parsing.

	parse_args is pure, so every branch can be checked directly with no process side effects.
*/

import "core:strings"
import "core:testing"

import "../../norn"

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

	_, ok_bad, _ := parse_args({"--format", "fancy"})
	testing.expect(t, !ok_bad, "unknown format should fail")
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
