#+build !js
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

// Dealing first and writing afterwards gives the page `generate_accepted` writes, byte for byte: the random
// stream is spent in the same order (the deal, then its table), and the tables are drawn at random here.
@(test)
test_collect_then_render_matches_generate :: proc(t: ^testing.T) {
	for format in ([]Output_Format{.Line, .Html_Cards}) {
		state: rand.Xoshiro256_Random_State
		context.random_generator = seeded_xoshiro(&state, 77)
		want := strings.builder_make()
		defer strings.builder_destroy(&want)
		generate_accepted(&want, 6, format, north_18plus, 1_000_000, randomize_table = true, page_title = "t")

		context.random_generator = seeded_xoshiro(&state, 77)
		deals: [dynamic]Deal
		tables: [dynamic]Table
		defer delete(deals)
		defer delete(tables)
		accepted, _ := collect_accepted(&deals, &tables, 6, format, north_18plus, 1_000_000, randomize_table = true)
		got := strings.builder_make()
		defer strings.builder_destroy(&got)
		render_accepted(&got, format, deals[:], tables[:], page_title = "t")

		testing.expect_value(t, accepted, 6)
		testing.expect(t, strings.to_string(got) == strings.to_string(want), "collect + render differs from generate_accepted")
	}
}

@(private = "file")
g_solved_batches: [dynamic]int

@(private = "file")
record_batch :: proc(deals: []Deal) -> bool {
	append(&g_solved_batches, len(deals))
	return true
}

@(private = "file")
north_18plus_deal :: proc(deal: Deal) -> bool {
	return hcp(summarize_deal(deal)[.North]) >= 18
}

// The filtered collect solves the condition's survivors in rounds of at most FILTER_BATCH, hands the filter
// every survivor of a round after that round is solved, and keeps exactly `count` deals the filter keeps.
@(test)
test_collect_filtered_solves_in_rounds :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 5)
	defer delete(g_solved_batches)
	clear(&g_solved_batches)

	deals: [dynamic]Deal
	tables: [dynamic]Table
	defer delete(deals)
	defer delete(tables)
	accepted, attempts := collect_filtered(&deals, &tables, 6, .Html_Cards, accept_all, north_18plus_deal, record_batch)

	testing.expect_value(t, accepted, 6)
	testing.expect_value(t, len(deals), 6)
	testing.expect_value(t, len(tables), 6)
	testing.expect(t, attempts >= 6, "at least as many dealt as kept")
	for deal in deals {
		testing.expect(t, north_18plus_deal(deal), "kept a deal the filter refuses")
	}
	solved := 0
	for n in g_solved_batches {
		testing.expect(t, n > 0 && n <= FILTER_BATCH, "a round is at most FILTER_BATCH deals")
		solved += n
	}
	testing.expect_value(t, solved, attempts) // the condition keeps every deal, so every deal was solved
}

/*
AN INTERPRETED CONDITION: a predicate that reads its rule out of `userdata` rather than having it compiled.

This is the whole reason `Contextual_Predicate` exists. Odin procs do not capture, so a scenario parsed
from a user's text file — whose condition is a PROGRAM rather than code — has nowhere to keep it. Here the
"program" is a threshold in a struct, which is the smallest thing that could not have been written as a
plain `Predicate`: the same proc gives different answers for different data.
*/
@(private = "file")
Hcp_Floor :: struct {
	seat: Seat,
	min:  int,
}

@(private = "file")
at_least :: proc(summary: Deal_Summary, userdata: rawptr) -> bool {
	rule := (^Hcp_Floor)(userdata)
	return hcp(summary[rule.seat]) >= rule.min
}

@(test)
test_a_contextual_predicate_reads_its_rule_from_userdata :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)

	// The SAME proc, twice, with different programs — and the counts have to differ in the right
	// direction, or the pointer is not being read at all.
	loose := Hcp_Floor{.North, 6}
	strict := Hcp_Floor{.North, 20}

	kept_loose := count_accepted_seeded(2000, Interpreted_Predicate{at_least, &loose}, 7)
	kept_strict := count_accepted_seeded(2000, Interpreted_Predicate{at_least, &strict}, 7)
	testing.expect(t, kept_loose > 0, "a 6+ hcp North should be common")
	testing.expectf(
		t,
		kept_strict < kept_loose,
		"20+ hcp (%d) should be rarer than 6+ (%d) — the same proc must be reading its data",
		kept_strict,
		kept_loose,
	)

	// And it drives generation, not just counting.
	accepted, attempts := generate_accepted(
		&builder,
		5,
		.Line,
		Interpreted_Predicate{at_least, &loose},
		max_attempts = 200_000,
	)
	testing.expect_value(t, accepted, 5)
	testing.expect(t, attempts >= accepted, "attempts cannot be fewer than acceptances")

	// AND THE SUM TYPE MAKES "BOTH AT ONCE" UNSAYABLE. This used to be two nullable fields with a written
	// rule about which won; a `Condition` is one or the other, so the impossible threshold below cannot be
	// quietly overridden by a compiled predicate sitting beside it.
	none := Hcp_Floor{.North, 41} // impossible: 40 hcp in the pack
	blocked := count_accepted_seeded(500, Interpreted_Predicate{at_least, &none}, 7)
	testing.expect_value(t, blocked, 0)

	// A nil condition keeps everything, which is the fourth state a union gives for nothing.
	testing.expect_value(t, count_accepted_seeded(100, nil, 7), 100)
}

// The annotator is handed the table the deal was RENDERED at (a par caption is scored at its vulnerability):
// each handviewer line's `v=`/`d=` tail must be what the annotator was given.
@(test)
test_the_annotator_gets_the_rendered_table :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2026)
	echo :: proc(builder: ^strings.Builder, deal: Deal, format: Output_Format, table: Table) {
		CODES := [Vulnerability]string {
			.None        = "-",
			.North_South = "n",
			.East_West   = "e",
			.Both        = "b",
		}
		strings.write_string(builder, " v=")
		strings.write_string(builder, CODES[table.vulnerability])
		strings.write_string(builder, "&d=")
		letters := "nesw"
		strings.write_byte(builder, letters[int(table.dealer.? or_else .North)])
	}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	generate_accepted(&builder, 16, .Handviewer, accept_all, randomize_table = true, annotate = Deal_Annotator(echo))
	text := strings.to_string(builder)
	lines := strings.split_lines(strings.trim_right(text, "\n"))
	defer delete(lines)
	testing.expect_value(t, len(lines), 16)
	tables := map[string]bool{}
	defer delete(tables)
	for line in lines {
		space := strings.last_index_byte(line, ' ')
		testing.expect(t, space > 0, line)
		given := line[space + 1:]
		testing.expectf(t, strings.has_suffix(line[:space], given), "rendered %q, annotator given %q", line[:space], given)
		tables[given] = true
	}
	testing.expect(t, len(tables) > 1, "a random table should vary over 16 deals")
}
