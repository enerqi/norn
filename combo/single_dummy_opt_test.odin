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

// AQT9542 opposite J6 (K873 missing): none of the fixed lines is the best play, and the search - which only
// finishes since the layouts are merged by interval - finds better (6.45 against 6.27; by a third of a trick
// before the fixed lines learnt to run a card and to lead toward honours, 2026-10-15).
@(test)
test_opt_beats_the_fixed_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n, s := mask(.Ace, .Queen, .Ten, .Nine, .Five, .Four, .Two), mask(.Jack, .Six)
	opt, exact := sd_optimal_expected_tricks(n, s)
	testing.expect(t, exact, "should solve exactly within the default budget")
	best := best_candidate_mean(n, s)
	testing.expectf(t, opt > best + 0.15, "optimal %.3f should beat the best fixed line %.3f", opt, best)
	testing.expectf(t, opt <= expected_tricks(suit_trick_distribution(n, s).p) + 1e-9, "and stay under the census")
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
