package norn

/*
	summary_test.odin — the bitmask index must agree with the scan-based primitives exactly.

	Rather than re-derive expected values, these tests assert the `s_*` ops equal their
	`evaluate.odin` twins over the shared test hands. If the two ever diverge, a predicate written
	against one representation would behave differently against the other.
*/

import "core:testing"

@(test)
test_summary_matches_scan :: proc(t: ^testing.T) {
	hands := [?]Hand{balanced_4333(), two_suiter_5422(), unbalanced_7222(), balanced_5332()}
	for hand in hands {
		s := summarize(hand)
		testing.expect_value(t, s_hcp(s), hcp(hand))
		testing.expect_value(t, s_controls(s), controls(hand))
		testing.expect_value(t, s_pattern(s), pattern(hand))
		testing.expect_value(t, s_shape(s), shape(hand))
		testing.expect_value(t, s_is_nt5cM_shape(s), is_nt5cM_shape(hand))
		for suit in Suit {
			testing.expect_value(t, s_suit_length(s, suit), suit_length(hand, suit))
			testing.expect_value(t, s_top5q(s, suit), top5q(hand, suit))
			for n in 0 ..= 5 {
				testing.expect_value(t, s_top_count(s, suit, n), top_count(hand, suit, n))
			}
			for rank in Rank {
				testing.expect_value(t, s_holds(s, suit, rank), holds(hand, suit, rank))
			}
		}
	}
}
