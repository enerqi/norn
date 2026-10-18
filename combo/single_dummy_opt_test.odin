#+build !js
package combo

/*
	single_dummy_opt_test.odin — tests for the optimal single-dummy search (single_dummy_opt.odin).

	Exact search is only tractable when NS holds most of the suit (few missing cards), so the exact
	tests use LONG holdings (small m). Coverage:
	  * bounds that must always hold: best fixed candidate <= optimal <= double-dummy census;
	  * a no-guess holding where optimal == census exactly;
	  * a genuine TWO-WAY guess (finesse either opponent for a queen) where the blind optimum is
	    STRICTLY below the census — proof the search actually confronts a guess rather than peeking;
	  * a short holding that blows the budget falls back to a valid distribution (exact = false).
*/

import "core:testing"

import "../norn"

@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

@(private = "file")
best_candidate_mean :: proc(north, south: u16) -> f64 {
	lines := candidate_lines()
	best := f64(-1)
	for line in lines {
		d := sd_line_distribution(north, south, line)
		mn := expected_tricks(d.p)
		if mn > best {
			best = mn
		}
	}
	return best
}

// A running suit — North AKQJT9 (6), South 87654 (5), opponents hold only the two lowest cards. Both
// NS hands follow every trick (two cards spent per trick), so the suit is worth max(6, 5) = 6 tricks,
// not 11 — and the optimal search confirms it exactly, matching the (now-fixed) census.
@(test)
test_opt_no_guess_equals_census :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := mask(.Ace, .King, .Queen, .Jack, .Ten, .Nine)
	s := mask(.Eight, .Seven, .Six, .Five, .Four)
	dist, exact := sd_optimal_distribution(n, s)
	census := suit_trick_distribution(n, s)

	testing.expect(t, exact, "a running holding with few missing cards should solve exactly")
	testing.expectf(t, abs(dist.p[6] - 1) < 1e-9, "should take exactly 6 tricks, P(6) = %v", dist.p[6])
	testing.expectf(
		t,
		abs(expected_tricks(dist.p) - expected_tricks(census.p)) < 1e-9,
		"optimal %.3f should equal census %.3f",
		expected_tricks(dist.p),
		expected_tricks(census.p),
	)
}

// The core invariant, on an exactly-solvable holding: best fixed candidate <= optimal <= census.
@(test)
test_opt_within_bounds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Two-way-queen holding (see the strict test below) — 10 cards, only 3 missing, so exact.
	n := mask(.Ace, .Jack, .Nine, .Seven, .Five)
	s := mask(.King, .Ten, .Eight, .Six, .Four)

	opt, exact := sd_optimal_expected_tricks(n, s)
	testing.expect(t, exact, "10-card holding (3 missing) should solve exactly")

	cand := best_candidate_mean(n, s)
	census := expected_tricks(suit_trick_distribution(n, s).p)

	testing.expectf(t, opt >= cand - 1e-9, "optimal %.3f must be >= best candidate %.3f", opt, cand)
	testing.expectf(t, opt <= census + 1e-9, "optimal %.3f must be <= census %.3f", opt, census)
}

// A genuine two-way finesse for the queen (North A J …, South K T …, queen missing and guarded). The
// double-dummy census always guesses right; a BLIND declarer cannot, so the optimum is strictly below
// the census. This proves the search models declarer's guess rather than peeking at the split.
@(test)
test_opt_two_way_guess_below_census :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := mask(.Ace, .Jack, .Nine, .Seven, .Five)
	s := mask(.King, .Ten, .Eight, .Six, .Four)

	opt, exact := sd_optimal_expected_tricks(n, s)
	census := expected_tricks(suit_trick_distribution(n, s).p)

	testing.expect(t, exact, "should solve exactly")
	testing.expectf(t, census - opt > 0.02, "blind optimum %.3f should trail census %.3f by a real guess", opt, census)
}

// A holding past the budget falls back to a valid distribution (flagged non-exact) rather than crashing
// or returning garbage. Nine cards opposite AQT9542/J6 needs a real search; a budget of 1,000 cannot do it.
@(test)
test_opt_falls_back_past_the_budget :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n, s := u16(0x0150), u16(0x14a1)
	dist, exact := sd_optimal_distribution(n, s, budget = 1_000)
	sum := f64(0)
	for k in 0 ..= RANKS {
		sum += dist.p[k]
	}
	testing.expectf(t, abs(sum - 1) < 1e-9, "fallback distribution must still sum to 1, got %v", sum)
	testing.expect(t, !exact, "a thousand units of work should not finish this holding")
	// Whatever the path, the mean cannot exceed the double-dummy census.
	census := expected_tricks(suit_trick_distribution(n, s).p)
	testing.expectf(
		t,
		expected_tricks(dist.p) <= census + 1e-9,
		"fallback mean %.3f must be <= census %.3f",
		expected_tricks(dist.p),
		census,
	)
}

// Nine missing cards used to be hopeless (512 layouts, overflowing at once). Merged by interval they are 18
// worlds, and AQ opposite 32 solves exactly in about a second - given a bake's budget rather than the live
// default - confirming the finesse as the optimum (the census is a hair higher: a singleton king offside
// drops under the ace double dummy, which no blind line can count on).
@(test)
test_opt_solves_nine_missing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n, s := mask(.Ace, .Queen), mask(.Three, .Two)
	dist, exact := sd_optimal_distribution(n, s, budget = 30_000_000)
	testing.expect(t, exact, "AQ opposite 32 should be exact with a bake's budget")
	opt := expected_tricks(dist.p)
	testing.expectf(t, abs(opt - best_candidate_mean(n, s)) < 1e-9, "the finesse is the optimum, got %.4f", opt)
}

// K74 opposite Q9865 (A J T 3 2 missing): the search beats every fixed line by a fifth of a trick (3.12 against
// 2.92), the biggest gap a sweep of random holdings finds (`just combo-line-sweep`, 2026-10-18): it ducks the
// first round unless West plays the J or T, then leads toward the Q, then the K - a play that depends on which
// card West showed, which no fixed line reads.
//
// The earlier holdings here were BUGS, not limits of fixed lines, and are pinned below as ties so a gap reopening
// shows. AQT9542 opposite J6 (0.18, until 2026-10-17): the finesse lines put in the cheapest card beating the
// second hand rather than the finesse card, overtook a partner's winning ace, and switched sides halfway.
// AQJ64 opposite 9852 (0.32, until 2026-10-18, recorded as "the best play leads the nine"): the only finesse
// line took the deep finesse of the 9 against the ten before, and after, the J against the king; `finesse-high`
// finesses against the king alone and takes the optimum. J3 opposite KT9842 (0.20, the next): `line_finesse`
// overtook the J run on the second round with the K, and `line_run` ran it on the first; `finesse-then-run` puts
// in the 8, then runs the J, and takes the optimum on every layout.
@(test)
test_opt_beats_the_fixed_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n, s := mask(.King, .Seven, .Four), mask(.Queen, .Nine, .Eight, .Six, .Five)
	opt, exact := sd_optimal_expected_tricks(n, s)
	testing.expect(t, exact, "should solve exactly within the default budget")
	best := best_candidate_mean(n, s)
	testing.expectf(t, opt > best + 0.15, "optimal %.3f should beat the best fixed line %.3f", opt, best)
	testing.expectf(t, opt <= expected_tricks(suit_trick_distribution(n, s).p) + 1e-9, "and stay under the census")

	ties := [][2]u16 {
		{mask(.Ace, .Queen, .Ten, .Nine, .Five, .Four, .Two), mask(.Jack, .Six)},
		{mask(.Ace, .Queen, .Jack, .Six, .Four), mask(.Nine, .Eight, .Five, .Two)},
		{mask(.Jack, .Three), mask(.King, .Ten, .Nine, .Eight, .Four, .Two)},
	}
	for h in ties {
		opt, exact = sd_optimal_expected_tricks(h[0], h[1])
		testing.expectf(t, exact, "%04x/%04x should solve exactly", h[0], h[1])
		best = best_candidate_mean(h[0], h[1])
		testing.expectf(t, abs(opt - best) < 1e-9, "%04x/%04x: the finesse lines take the optimum %.4f, got %.4f", h[0], h[1], opt, best)
	}
}

// A defender may cover an honour: with K986432 opposite J75 (A Q T missing), the jack led from North is
// covered by the queen. The search once took declarer's card off the table before the defender chose, so
// the queen and ten looked like equals and only the ten was ever played - 5.65 tricks. With the cover, 5.52.
@(test)
test_opt_the_defence_covers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n, s := mask(.Jack, .Seven, .Five), mask(.King, .Nine, .Eight, .Six, .Four, .Three, .Two)
	opt, exact := sd_optimal_expected_tricks(n, s)
	testing.expect(t, exact, "should solve exactly")
	testing.expectf(t, abs(opt - 5.52) < 1e-6, "expected 5.52 with the cover, got %.6f", opt)
}
