package norn

/*
	summary_test.odin — the bitmask index must agree with the scan-based primitives exactly.

	Rather than re-derive expected values, these tests assert the `s_*` ops equal their
	`evaluate.odin` twins over the shared test hands. If the two ever diverge, a predicate written
	against one representation would behave differently against the other.
*/

import "core:math/rand"
import "core:testing"

// Assert every `s_*` op equals its scan-based twin for one hand.
@(private = "file")
expect_summary_matches :: proc(t: ^testing.T, hand: Hand, loc := #caller_location) {
	s := summarize(hand)
	testing.expect_value(t, s_hcp(s), hcp(hand), loc = loc)
	testing.expect_value(t, s_controls(s), controls(hand), loc = loc)
	testing.expect_value(t, s_pattern(s), pattern(hand), loc = loc)
	testing.expect_value(t, s_shape(s), shape(hand), loc = loc)
	testing.expect_value(t, s_is_nt5cM_shape(s), is_nt5cM_shape(hand), loc = loc)
	testing.expect_value(t, s_is_balanced(s), is_balanced(hand), loc = loc)
	testing.expect_value(t, s_is_semibalanced(s), is_semibalanced(hand), loc = loc)
	testing.expect_value(t, s_is_spade_shape(s), is_spade_shape(hand), loc = loc)
	testing.expect_value(t, s_is_heart_shape(s), is_heart_shape(hand), loc = loc)
	testing.expect_value(t, s_is_diamond_shape(s), is_diamond_shape(hand), loc = loc)
	testing.expect_value(t, s_is_club_shape(s), is_club_shape(hand), loc = loc)
	testing.expect_value(t, s_losers(s), losers(hand), loc = loc)
	testing.expect_value(t, s_op(s), op(hand), loc = loc)
	testing.expect_value(t, s_dhcp(s), dhcp(hand), loc = loc)
	testing.expect_value(t, s_new_ltc(s), new_ltc(hand), loc = loc)
	for min in 10 ..= 20 {
		testing.expect_value(t, s_is_nt(s, min, min + 2), is_nt(hand, min, min + 2), loc = loc)
	}
	for suit in Suit {
		testing.expect_value(t, s_suit_length(s, suit), suit_length(hand, suit), loc = loc)
		testing.expect_value(t, s_top5q(s, suit), top5q(hand, suit), loc = loc)
		testing.expect_value(t, s_offense(s, suit), offense(hand, suit), loc = loc)
		testing.expect_value(t, s_defense(s, suit), defense(hand, suit), loc = loc)
		for n in 0 ..= 5 {
			testing.expect_value(t, s_top_count(s, suit, n), top_count(hand, suit, n), loc = loc)
		}
		for rank in Rank {
			testing.expect_value(t, s_holds(s, suit, rank), holds(hand, suit, rank), loc = loc)
		}
	}
}

@(test)
test_summary_matches_scan :: proc(t: ^testing.T) {
	hands := [?]Hand{balanced_4333(), two_suiter_5422(), unbalanced_7222(), balanced_5332()}
	for hand in hands {
		expect_summary_matches(t, hand)
	}
}

// The fixed fixtures above can't hit every branch of `offense`/`defense`/`losers` (the honour
// combinations). Deal a large sample of random hands and assert the index agrees with the scan on
// all of them, so the honour-weighted branches are exercised too.
@(test)
test_summary_matches_scan_random :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 0xC0FFEE)
	for _ in 0 ..< 2000 {
		board := deal_board()
		for seat in Seat {
			expect_summary_matches(t, board[seat])
		}
	}
}
