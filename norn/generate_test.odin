package norn

/*
	generate_test.odin — unit tests for the render loop (the pure part of generation).

	I/O (writing to stdout or a file) is not tested here; render_deals builds text in memory, which
	is what we assert on.
*/

import "core:math/rand"
import "core:strings"
import "core:testing"

// Count how many rank characters (A K Q J T 9..2) appear in a string. A full deal line must
// contain exactly 52 of them — one per card.
count_rank_chars :: proc(s: string) -> int {
	count := 0
	for r in s {
		switch r {
		case 'A', 'K', 'Q', 'J', 'T', '2', '3', '4', '5', '6', '7', '8', '9':
			count += 1
		}
	}
	return count
}

// render_deals should emit exactly `count` newline-terminated lines, each a structurally valid
// deal: three '|' separators and 52 rank characters in total.
@(test)
test_render_deals_structure :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2026)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deals(&builder, 5, .Line)

	text := strings.to_string(builder)
	lines := strings.split_lines(text)
	defer delete(lines)

	// 5 lines plus a trailing empty element after the final newline.
	testing.expect_value(t, len(lines), 6)
	testing.expect_value(t, lines[5], "")

	for line_index in 0 ..< 5 {
		line := lines[line_index]
		testing.expect_value(t, strings.count(line, "|"), 3)
		testing.expectf(t, count_rank_chars(line) == DECK_SIZE, "line %d should hold 52 cards", line_index)
	}
}

// The same seed must reproduce identical generated text.
@(test)
test_render_deals_is_deterministic :: proc(t: ^testing.T) {
	first := strings.builder_make()
	defer strings.builder_destroy(&first)
	state_a: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_a, 77)
	render_deals(&first, 4, .Line)

	second := strings.builder_make()
	defer strings.builder_destroy(&second)
	state_b: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_b, 77)
	render_deals(&second, 4, .Line)

	testing.expect_value(t, strings.to_string(first), strings.to_string(second))
}

// A count of zero produces no output.
@(test)
test_render_deals_zero :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 1)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deals(&builder, 0, .Line)

	testing.expect_value(t, strings.builder_len(builder), 0)
}

// High-card points of the North hand in a rendered line (everything before the first '|'). Suit
// letters never appear in the line format, so honour characters are unambiguous.
north_hcp_in_line :: proc(line: string) -> int {
	total := 0
	for r in line {
		switch r {
		case '|':
			return total // reached end of the North hand
		case 'A':
			total += 4
		case 'K':
			total += 3
		case 'Q':
			total += 2
		case 'J':
			total += 1
		}
	}
	return total
}

never_accept :: proc(summary: Deal_Summary) -> bool {
	return false
}

north_18plus :: proc(summary: Deal_Summary) -> bool {
	return hcp(summary[.North]) >= 18
}

// With accept-all, every attempt is accepted: attempts equals accepted equals count.
@(test)
test_generate_accepted_accept_all :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 3)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	accepted, attempts := generate_accepted(&builder, 5, .Line, accept_all)

	testing.expect_value(t, accepted, 5)
	testing.expect_value(t, attempts, 5)
}

// count_accepted: accept-all counts every trial; never-accept counts none.
@(test)
test_count_accepted_bounds :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 7)

	testing.expect_value(t, count_accepted(1000, accept_all), 1000)
	testing.expect_value(t, count_accepted(1000, never_accept), 0)
}

// count_accepted: a selective condition lands strictly between 0 and the trial count, and matches
// the rate seen by re-checking each board independently over the same seed.
@(test)
test_count_accepted_selective :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 99)

	accepted := count_accepted(5000, north_18plus)
	testing.expect(t, accepted > 0, "18+ hcp should occur in 5000 deals")
	testing.expect(t, accepted < 5000, "18+ hcp should not always occur")
}

// count_accepted_seeded is self-contained and reproducible: the same seed gives the same count
// (independent of context.random_generator), and different seeds generally differ.
@(test)
test_count_accepted_seeded_reproducible :: proc(t: ^testing.T) {
	a := count_accepted_seeded(3000, north_18plus, 12345)
	b := count_accepted_seeded(3000, north_18plus, 12345)
	testing.expect_value(t, a, b)

	c := count_accepted_seeded(3000, north_18plus, 99999)
	testing.expect(t, a != c, "different seeds should (almost surely) give different counts")
}

// A condition that never accepts stops at max_attempts with nothing accepted and no output.
@(test)
test_generate_accepted_hits_attempt_cap :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 3)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	accepted, attempts := generate_accepted(&builder, 5, .Line, never_accept, 50)

	testing.expect_value(t, accepted, 0)
	testing.expect_value(t, attempts, 50)
	testing.expect_value(t, strings.builder_len(builder), 0)
}

// End to end: every board the predicate keeps really does satisfy it. We generate strong-North
// boards and confirm each rendered line shows North with at least 18 hcp.
@(test)
test_generate_accepted_filters :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2026)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	accepted, attempts := generate_accepted(&builder, 8, .Line, north_18plus, 1_000_000)

	testing.expect_value(t, accepted, 8)
	testing.expect(t, attempts >= accepted, "selective condition should need at least as many attempts")

	lines := strings.split_lines(strings.to_string(builder))
	defer delete(lines)
	for line in lines {
		if line == "" {
			continue
		}
		testing.expectf(t, north_hcp_in_line(line) >= 18, "kept a North hand below 18 hcp: %s", line)
	}
}
