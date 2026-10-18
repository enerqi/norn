#+build !js
package combo

/*
	single_dummy_policy_test.odin — tests for the suit solver's LINE and its guaranteed value
	(single_dummy_policy.odin).

	  * a line's value against the best defence never exceeds the search's own value, and the search's value
	    through the policy is the optimal search's;
	  * the plain finesse is proven optimal;
	  * a holding whose searched line beats the best fixed line, though not by the search's full value;
	  * a holding whose search does not finish but whose relabelled search gives a better line;
	  * the small-spot relabel itself.
*/

import "core:testing"

@(private = "file")
mean_of :: proc(d: Suit_Trick_Dist) -> f64 {
	return expected_tricks(d.p)
}

@(test)
test_policy_value_never_exceeds_the_search :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	holdings := [][2]u16{{0x1400, 0x0003}, {0x0150, 0x14a1}, {0x0228, 0x08d7}}
	for h in holdings {
		pol := sd_policy_make(h[0], h[1], 10_000_000)
		defer sd_policy_destroy(pol)
		search, ok1 := sd_policy_search_value(pol)
		line, ok2 := sd_policy_evaluate(pol, h[0], h[1], SD_POLICY_IDENTITY)
		opt, exact := sd_optimal_distribution(h[0], h[1], 10_000_000)
		testing.expectf(t, ok1 && ok2 && exact, "%04x/%04x should finish", h[0], h[1])
		testing.expectf(
			t,
			mean_of(line) <= mean_of(search) + 1e-9,
			"%04x/%04x: the line's value %.4f is above the search's %.4f",
			h[0],
			h[1],
			mean_of(line),
			mean_of(search),
		)
		testing.expectf(
			t,
			abs(mean_of(search) - mean_of(opt)) < 1e-9,
			"%04x/%04x: the policy's search %.4f differs from the optimal search %.4f",
			h[0],
			h[1],
			mean_of(search),
			mean_of(opt),
		)
	}
}

// AQ opposite 32: the finesse, 1.5 tricks, and nothing does better.
@(test)
test_certified_finesse_is_optimal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := sd_certified_line(0x1400, 0x0003)
	defer sd_certified_destroy(&c)
	testing.expectf(t, abs(mean_of(c.dist) - 1.5) < 1e-9, "AQ/32 should be worth 1.5, got %.4f", mean_of(c.dist))
	testing.expect(t, c.optimal, "the finesse should be proven optimal")
}

// T86 opposite AQ972: the searched line takes 3.896 against the best defence, against 3.857 for the best
// fixed line (3.760 before the finesse lines were repaired, 2026-10-17) - but not the search's own 3.980,
// which assumed declarer knew the defence's scheme.
@(test)
test_certified_search_line_beats_the_fixed_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := sd_certified_line(0x0150, 0x14a1)
	defer sd_certified_destroy(&c)
	fixed := mean_of(best_line_by_mean(0x0150, 0x14a1).dist)
	testing.expect_value(t, c.source, Line_Source.Search)
	testing.expectf(t, abs(mean_of(c.dist) - 3.8957) < 1e-3, "T86/AQ972 line %.4f, expected 3.8957", mean_of(c.dist))
	testing.expectf(t, mean_of(c.dist) > fixed + 0.03, "line %.4f should beat the fixed %.4f", mean_of(c.dist), fixed)
	testing.expect(t, !c.optimal, "the line falls short of the search's value, so it is not proven optimal")
	testing.expect(t, c.policy != nil, "a searched line carries its policy")
}

// JT7 opposite AK653: the search does not finish at the default budget, the relabelled one does, and its
// line, played with the real cards, takes 4.357 against 3.967 for the best fixed line.
@(test)
test_certified_relabelled_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := sd_certified_line(0x0320, 0x181a)
	defer sd_certified_destroy(&c)
	testing.expect_value(t, c.source, Line_Source.Relabel)
	testing.expectf(t, abs(mean_of(c.dist) - 4.3565) < 1e-3, "JT7/AK653 line %.4f, expected 4.3565", mean_of(c.dist))
}

// N 7 5 3, S 8 6: below the eight, declarer's 3 5 6 7 become 2 3 4 5 and the defenders' 2 4 become 6 7.
@(test)
test_small_spot_perm :: proc(t: ^testing.T) {
	n := rank_bit(1) | rank_bit(3) | rank_bit(5) // 3 5 7
	s := rank_bit(4) | rank_bit(6) // 6 8
	perm := small_spot_perm(n, s, SMALL_SPOTS_BELOW)
	testing.expect_value(t, perm_mask(n, perm), rank_bit(0) | rank_bit(1) | rank_bit(3))
	testing.expect_value(t, perm_mask(s, perm), rank_bit(2) | rank_bit(6))
	testing.expect_value(t, perm[0], 4) // the defenders' 2 becomes the 6
	testing.expect_value(t, perm[2], 5) // and their 4 the 7
}
