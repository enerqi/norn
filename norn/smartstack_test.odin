package norn

/*
	smartstack_test.odin — unit tests for shape/strength-biased generation.

	Two kinds of check: the combinatorics (the weights must be EXACT counts, verified against closed
	forms like Vandermonde's identity) and the sampler (every hand it produces must satisfy the
	constraint, the full deal must stay a legal 52-card deal, and a fixed seed must reproduce).
*/

import "core:math/rand"
import "core:testing"

// Binomial C(n, k), computed without overflow for the small n used here.
@(private = "file")
binomial :: proc(n, k: int) -> i64 {
	if k < 0 || k > n {
		return 0
	}
	kk := min(k, n - k)
	result: i64 = 1
	for i in 0 ..< kk {
		result = result * i64(n - i) / i64(i + 1)
	}
	return result
}

// A shape (s-h-d-c lengths) is balanced by deal's rule: no 5-card major, sum of squared lengths <= 47.
@(private = "file")
keep_balanced :: proc(shape: [SUIT_COUNT]int) -> bool {
	s, h, d, c := shape[0], shape[1], shape[2], shape[3]
	if s >= 5 || h >= 5 {
		return false
	}
	return s * s + h * h + d * d + c * c <= 47
}

@(private = "file")
keep_all :: proc(shape: [SUIT_COUNT]int) -> bool {
	return true
}

// The suit kernel must be an exact count: summed over points, length-L holdings number C(13, L).
@(test)
test_suit_hcp_table_totals :: proc(t: ^testing.T) {
	table := build_suit_hcp_table()
	for length in 0 ..= RANK_COUNT {
		sum: i64
		for p in 0 ..= MAX_SUIT_HCP {
			sum += table[length][p]
		}
		testing.expectf(
			t,
			sum == binomial(RANK_COUNT, length),
			"length %d: got %d holdings, want C(13,%d)=%d",
			length,
			sum,
			length,
			binomial(RANK_COUNT, length),
		)
	}
	// Spot checks: a void has 0 points exactly one way; a 13-card suit holds all honours (10 hcp).
	testing.expect_value(t, table[0][0], 1)
	testing.expect_value(t, table[13][10], 1)
	testing.expect_value(t, table[13][9], 0)
}

// Over EVERY shape and the full hcp window, the total weight must equal the number of 13-card hands,
// C(52, 13) — a Vandermonde check that the per-shape weights are exact and complete.
@(test)
test_smartstack_total_weight_is_all_hands :: proc(t: ^testing.T) {
	ss, ok := smartstack_make_filtered(.North, keep_all, 0, 40)
	testing.expect(t, ok, "all shapes / full hcp must admit hands")
	testing.expect_value(t, ss.shape_count, MAX_SHAPES)
	testing.expect_value(t, ss.total_weight, binomial(DECK_SIZE, HAND_SIZE))
}

// An impossible constraint is reported, not silently sampled: a 13-card spade suit holds A K Q J, so
// at least 10 hcp — a [0,5] window admits nothing.
@(test)
test_smartstack_impossible :: proc(t: ^testing.T) {
	shapes := [][SUIT_COUNT]int{{13, 0, 0, 0}}
	_, ok := smartstack_make(.North, shapes, 0, 5)
	testing.expect(t, !ok, "13 spades cannot be under 6 hcp")
}

// A reversed window is rejected.
@(test)
test_smartstack_bad_range :: proc(t: ^testing.T) {
	_, ok := smartstack_make_filtered(.North, keep_all, 20, 10)
	testing.expect(t, !ok, "hcp_min > hcp_max must fail")
}

// A shape whose lengths don't sum to 13 is rejected.
@(test)
test_smartstack_bad_shape :: proc(t: ^testing.T) {
	shapes := [][SUIT_COUNT]int{{4, 4, 4, 4}} // 16 cards
	_, ok := smartstack_make(.North, shapes, 0, 40)
	testing.expect(t, !ok, "lengths must sum to 13")
}

// Every sampled hand must actually satisfy the constraint: balanced shape and hcp in [15,17].
@(test)
test_smartstack_hand_satisfies_constraint :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2026)

	ss, ok := smartstack_make_filtered(.South, keep_balanced, 15, 17)
	testing.expect(t, ok, "balanced 15-17 must admit hands")

	saw_15, saw_17 := false, false
	for _ in 0 ..< 3000 {
		hand := smartstack_hand(&ss)

		// Exactly 13 distinct cards.
		seen: [DECK_SIZE]bool
		for card in hand {
			testing.expect(t, !seen[int(card)], "duplicate card in stacked hand")
			seen[int(card)] = true
		}

		points := hcp(hand)
		testing.expectf(t, points >= 15 && points <= 17, "hcp %d outside 15-17", points)
		testing.expect(t, is_balanced(hand), "hand is not balanced")

		if points == 15 {saw_15 = true}
		if points == 17 {saw_17 = true}
	}
	// The window's extremes should both turn up — the sampler isn't stuck on one value.
	testing.expect(t, saw_15 && saw_17, "expected the full 15-17 range to appear")
}

// A specific long-suit constraint: 6+ spades, 10-13 hcp. Confirms shape biasing on a rare-ish target.
@(test)
test_smartstack_long_suit :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 7)

	keep_6plus_spades :: proc(shape: [SUIT_COUNT]int) -> bool {
		return shape[0] >= 6
	}
	ss, ok := smartstack_make_filtered(.North, keep_6plus_spades, 10, 13)
	testing.expect(t, ok, "6+ spades 10-13 must admit hands")

	for _ in 0 ..< 2000 {
		hand := smartstack_hand(&ss)
		testing.expect(t, spade_length(hand) >= 6, "fewer than 6 spades")
		points := hcp(hand)
		testing.expectf(t, points >= 10 && points <= 13, "hcp %d outside 10-13", points)
	}
}

// deal_board_smartstack must yield a legal full deal: 52 distinct cards, the stacked seat meeting
// its constraint, the others holding the rest.
@(test)
test_deal_board_smartstack_valid :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 99)

	ss, ok := smartstack_make_filtered(.East, keep_balanced, 20, 21)
	testing.expect(t, ok, "balanced 20-21 must admit hands")

	for _ in 0 ..< 500 {
		board := deal_board_smartstack(&ss)
		seen: [DECK_SIZE]bool
		for seat in Seat {
			for card in board[seat] {
				testing.expect(t, !seen[int(card)], "duplicate card across the deal")
				seen[int(card)] = true
			}
		}
		points := hcp(board[.East])
		testing.expectf(t, points >= 20 && points <= 21, "East hcp %d outside 20-21", points)
		testing.expect(t, is_balanced(board[.East]), "East not balanced")
	}
}

// A fixed seed reproduces the same stacked hands byte for byte.
@(test)
test_smartstack_deterministic :: proc(t: ^testing.T) {
	ss, ok := smartstack_make_filtered(.North, keep_balanced, 12, 14)
	testing.expect(t, ok, "balanced 12-14 must admit hands")

	first: [16]Hand
	state_a: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_a, 555)
	for i in 0 ..< 16 {
		first[i] = smartstack_hand(&ss)
	}

	state_b: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_b, 555)
	for i in 0 ..< 16 {
		again := smartstack_hand(&ss)
		testing.expect(t, again == first[i], "same seed should reproduce the same hand")
	}
}
