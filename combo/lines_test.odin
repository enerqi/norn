#+build !js
package combo

/*
	lines_test.odin — tests for the Phase-2 candidate-line generator (lines.odin).

	Run:  odin test combo -collection:norn=<norn> -out:target/debug/test-combo.exe

	Coverage:
	  * every candidate line yields a valid distribution;
	  * on the classic AQ-opp-xx finesse, `line_finesse` beats `line_top_down` and `best_line` picks it;
	  * the Pareto frontier is non-empty, internally non-dominated, and collapses to one line when the
	    holding is solid (all lines coincide);
	  * the compound candidates are registered; `line_finesse_other` finesses the WRONG way on a one-way
	    holding (a distinct, worse distribution); `line_duck_then_finesse` is a phased line that costs
	    nothing on a solid holding (the duck cannot be overtaken).
*/

import "core:strings"
import "core:math/rand"
import "core:testing"

import "../norn"

// A finesse-family recommendation on solid honours (no real tenace) is relabelled and narrated as the CASH it
// actually is — never a bogus "finesse the 7" on AKQ — while a genuine honour finesse is left untouched.
@(test)
test_finesse_relabelled_when_no_tenace :: proc(t: ^testing.T) {
	// KQ opposite A 7 4 3 -> combined AKQ743: the only card below the top missing (J) is a spot -> no finesse.
	solid_n, solid_s := mask(.King, .Queen), mask(.Ace, .Seven, .Four, .Three)
	testing.expect(t, !holding_has_real_finesse(solid_n, solid_s))
	testing.expect_value(t, display_line_name(solid_n, solid_s, "finesse-other"), "top-down")
	testing.expect_value(t, display_line_name(solid_n, solid_s, "duck-then-finesse"), "duck-one")
	tip := describe_suit_line(solid_n, solid_s, "finesse-other")
	testing.expect(t, !strings.contains(tip, "finesse")) // narrated as a cash, not a finesse

	// AK opposite J T 2 -> combined AKJT2, missing Q: the J is a real honour finesse card, so it stays a finesse.
	real_n, real_s := mask(.Ace, .King), mask(.Jack, .Ten, .Two)
	testing.expect(t, holding_has_real_finesse(real_n, real_s))
	testing.expect_value(t, display_line_name(real_n, real_s, "finesse"), "finesse")
}

@(private = "file")
mask :: proc(ranks: ..norn.Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << uint(r)
	}
	return m
}

// Every candidate line produces a probability distribution (sums to 1) on a spread of holdings.
@(test)
test_candidates_are_distributions :: proc(t: ^testing.T) {
	cases := [][2]u16 {
		{mask(.Ace, .Queen), mask(.Three, .Two)},
		{mask(.Ace, .King, .Jack), mask(.Four, .Three, .Two)},
		{mask(.King, .Queen, .Ten), mask(.Six, .Five, .Four)},
		{mask(.Ace, .King, .Queen), 0},
	}
	for c in cases {
		cands := suit_candidate_lines(c[0], c[1])
		defer delete(cands)
		for lr in cands {
			sum := f64(0)
			for k in 0 ..= RANKS {
				sum += lr.dist.p[k]
			}
			testing.expectf(t, abs(sum - 1) < 1e-9, "line %s: sum = %v, want 1", lr.name, sum)
		}
	}
}

// AQ opposite xx: the finesse line takes ~2 tricks half the time; top-down never does. So the finesse
// strictly beats top-down on both P(>=2) and mean.
@(test)
test_finesse_beats_top_down :: proc(t: ^testing.T) {
	n := mask(.Ace, .Queen)
	s := mask(.Three, .Two)
	top := sd_line_distribution(n, s, line_top_down)
	fin := sd_line_distribution(n, s, line_finesse)

	testing.expectf(
		t,
		p_at_least(fin.p, 2) > p_at_least(top.p, 2) + 0.3,
		"finesse P(>=2) %.3f should beat top-down %.3f",
		p_at_least(fin.p, 2),
		p_at_least(top.p, 2),
	)
	testing.expect(t, expected_tricks(fin.p) > expected_tricks(top.p) + 0.3, "finesse mean should beat top-down")
}

// `best_line` for a 2-trick target on AQ-opp-xx should choose the finesse.
@(test)
test_best_line_picks_finesse :: proc(t: ^testing.T) {
	best := best_line(mask(.Ace, .Queen), mask(.Three, .Two), 2)
	testing.expectf(t, best.name == "finesse", "best line for target 2 was %q, want finesse", best.name)
	testing.expect(t, p_at_least(best.dist.p, 2) > 0.4, "the finesse should make >=2 roughly half the time")
}

// The Pareto frontier is non-empty and internally consistent: no member dominates another.
@(test)
test_pareto_non_dominated :: proc(t: ^testing.T) {
	cands := suit_candidate_lines(mask(.Ace, .Queen), mask(.Three, .Two))
	defer delete(cands)
	front := pareto_lines(cands)
	defer delete(front)

	testing.expect(t, len(front) >= 1, "frontier must be non-empty")
	for a, i in front {
		for b, j in front {
			if i == j {
				continue
			}
			testing.expectf(t, !line_dominates(a.dist, b.dist), "pareto member %s dominates %s", b.name, a.name)
		}
	}
}

// A solid AKQ makes three tricks under every line, so the frontier de-duplicates to a single entry.
@(test)
test_pareto_collapses_when_solid :: proc(t: ^testing.T) {
	cands := suit_candidate_lines(mask(.Ace, .King, .Queen), 0)
	defer delete(cands)
	front := pareto_lines(cands)
	defer delete(front)
	testing.expectf(t, len(front) == 1, "solid suit should collapse to one frontier line, got %d", len(front))
}

// The two compound candidates are registered (they must appear in `candidate_lines` for the DP,
// `best_line`, and the card-page emit to pick them up).
@(test)
test_compound_lines_registered :: proc(t: ^testing.T) {
	lines := candidate_lines()
	have_other, have_dtf := false, false
	for l in lines {
		if l.name == "finesse-other" {have_other = true}
		if l.name == "duck-then-finesse" {have_dtf = true}
	}
	testing.expect(t, have_other, "finesse-other should be a registered candidate")
	testing.expect(t, have_dtf, "duck-then-finesse should be a registered candidate")
}

// On the one-way AQ-opp-xx, `line_finesse` leads TOWARD the AQ tenace; `line_finesse_other` leads the
// other way (into the tenace), which is the wrong guess. So the two directions are DISTINCT and the
// correct one takes strictly more tricks — i.e. exposing both directions gives the DP a real choice.
@(test)
test_finesse_other_is_distinct :: proc(t: ^testing.T) {
	n := mask(.Ace, .Queen)
	s := mask(.Three, .Two)
	fin := sd_line_distribution(n, s, line_finesse)
	oth := sd_line_distribution(n, s, line_finesse_other)

	testing.expect(t, !dist_near_equal(fin, oth), "the two finesse directions should differ on a one-way holding")
	testing.expectf(
		t,
		expected_tricks(fin.p) > expected_tricks(oth.p) + 1e-9,
		"finessing toward the tenace (%.3f) should beat the wrong way (%.3f)",
		expected_tricks(fin.p),
		expected_tricks(oth.p),
	)
}

// `line_duck_then_finesse` ducks round one then finesses. On a solid AKQ (opposite void) the duck cannot
// be overtaken — the opponents hold nothing above the Queen — so the phased line still takes all three
// tricks: the compound line costs nothing when there is nothing to lose, and its distribution is valid.
@(test)
test_duck_then_finesse_no_cost_when_solid :: proc(t: ^testing.T) {
	d := sd_line_distribution(mask(.Ace, .King, .Queen), 0, line_duck_then_finesse)
	sum := f64(0)
	for k in 0 ..= RANKS {sum += d.p[k]}
	testing.expectf(t, abs(sum - 1) < 1e-9, "distribution must sum to 1, got %v", sum)
	testing.expectf(
		t,
		abs(expected_tricks(d.p) - 3) < 1e-9,
		"solid AKQ should still take 3 tricks, got %.4f",
		expected_tricks(d.p),
	)
}

// The compound line EARNS its place: on AJ85 opposite 94, conceding the first round before finessing the jack
// out-scores every other candidate by mean tricks. Regression guard that the phased candidate is reachable, not
// dead weight. (AKJ7 opposite 63 was the holding until the finesse lines were repaired, 2026-10-17: the plain
// finesse had lost to the duck there only because it was broken. Found by a random-holding sweep.)
@(test)
test_duck_then_finesse_earns_its_place :: proc(t: ^testing.T) {
	n := mask(.Nine, .Four)
	s := mask(.Ace, .Jack, .Eight, .Five)
	dtf := expected_tricks(sd_line_distribution(n, s, line_duck_then_finesse).p)
	for line in candidate_lines() {
		if line.name == line_duck_then_finesse.name {
			continue
		}
		other := expected_tricks(sd_line_distribution(n, s, line).p)
		testing.expectf(t, dtf > other + 0.02, "duck-then-finesse %.4f should beat %s %.4f", dtf, line.name, other)
	}
	best := best_line_by_mean(n, s)
	testing.expect(t, expected_tricks(best.dist.p) >= dtf - 1e-9, "the best line is at least the compound one")
}

// --- guards: what the fixed lines must keep doing --------------------------------------------------------
//
// The finesse lines were broken for months (2026-10-17): the third hand put in the cheapest card beating the
// second hand rather than the finesse card, overtook its partner's winning ace, and a line switched sides once
// its finesse card was spent. Nothing failed. Double-dummy defence quietly EXPLOITS a senseless declarer play,
// so a broken line does not crash or print nonsense - it scores low, and another line (a duck) wins the
// comparison with a plausible label. The tests then in place checked chosen examples the way the author
// expected them to work, and the solver comparisons ("the search beats the fixed lines by 0.18") recorded the
// bug's cost as a property of fixed lines. The three tests below are the defence: known answers from the
// textbooks, a rule no line may break, and a ratchet against the exact optimum.

// The textbook combinations: the recommended line (best by mean) and its chance of the tricks that matter, as
// the books give them (vacant-space odds, the same as this model's). A finesse that stops finessing fails here.
@(test)
test_textbook_combinations :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		north:  u16,
		south:  u16,
		tricks: int, // the target
		p:      f64, // the book's chance of it
		tol:    f64,
		lines:  []string, // acceptable recommendations
	}
	finesses := []string{"finesse", "finesse-other", "finesse-high", "cash-then-finesse", "duck-then-finesse", "run", "finesse-then-run"}
	cases := []Case {
		// Low toward the jack: West's queen is onside half the time (and a singleton queen drops under the ace).
		{"KJ85/A4", mask(.King, .Jack, .Eight, .Five), mask(.Ace, .Four), 3, 0.50, 0.06, finesses},
		{"AQ/32", mask(.Ace, .Queen), mask(.Three, .Two), 2, 0.50, 0.01, finesses},
		// The double finesse: two tricks 76%, three 24%.
		{"AQT/432 two", mask(.Ace, .Queen, .Ten), mask(.Four, .Three, .Two), 2, 0.76, 0.005, finesses},
		{"AQT/432 three", mask(.Ace, .Queen, .Ten), mask(.Four, .Three, .Two), 3, 0.24, 0.005, finesses},
		// A two-way guess: half the time, whichever way it is taken.
		{"AJ2/KT3", mask(.Ace, .Jack, .Two), mask(.King, .Ten, .Three), 3, 0.50, 0.01, finesses},
		// Nine never: cash the ace and king, 53%; the finesse is 50%.
		{"AKJ432/765", mask(.Ace, .King, .Jack, .Four, .Three, .Two), mask(.Seven, .Six, .Five), 6, 0.53, 0.01, {"top-down", "toward"}},
		// Eight ever: finesse the jack.
		{"AKJ32/654", mask(.Ace, .King, .Jack, .Three, .Two), mask(.Six, .Five, .Four), 5, 0.34, 0.01, finesses},
		// Repeat the finesse against the king, and nothing deeper: the 9 is a finesse card too (against the ten),
		// and taking it first or after the jack loses made this 5.0 tricks; the book (and the optimum) is 5.5.
		{"AQJ952/8743", mask(.Ace, .Queen, .Jack, .Nine, .Five, .Two), mask(.Eight, .Seven, .Four, .Three), 6, 0.50, 0.005, finesses},
		// Ten cards missing the queen: the ace, and if East shows out, finesse through West - 89% for six tricks,
		// where the drop alone is 78%. A line that cannot see who showed out cannot play it.
		{"AKJT86/9432", mask(.Ace, .King, .Jack, .Ten, .Eight, .Six), mask(.Nine, .Four, .Three, .Two), 6, 0.89, 0.005, {"cash-then-discover"}},
		// The same, with the tenace the other side of the ace: cash the ace from the short hand, keep the K J.
		{"KJ8542/A976", mask(.King, .Jack, .Eight, .Five, .Four, .Two), mask(.Ace, .Nine, .Seven, .Six), 6, 0.89, 0.005, {"cash-then-discover"}},
	}
	for c in cases {
		best := best_line_by_mean(c.north, c.south)
		got := p_at_least(best.dist.p, c.tricks)
		testing.expectf(t, got >= c.p - c.tol, "%s: %s makes %d tricks %.4f, the book says %.2f", c.name, best.name, c.tricks, got, c.p)
		named := false
		for l in c.lines {
			named = named || l == best.name
		}
		testing.expectf(t, named, "%s: recommends %s, want one of %v", c.name, best.name, c.lines)
	}
	// Both ways of a two-way finesse take the same.
	aj, kt := mask(.Ace, .Jack, .Two), mask(.King, .Ten, .Three)
	one := expected_tricks(sd_line_distribution(aj, kt, line_finesse).p)
	other := expected_tricks(sd_line_distribution(aj, kt, line_finesse_other).p)
	testing.expectf(t, abs(one - 2.5) < 0.01 && abs(other - 2.5) < 0.01, "AJ2/KT3 both ways 2.5: %.4f and %.4f", one, other)
}

// A rule no line may break: with our side already winning the trick with a TOP card (nothing out above it),
// the other hand does not play a higher card while it holds a lower one. Double-dummy defence makes such a
// card cost a trick - West's queen thrown under South's ace drew North's king - and the cost only ever shows as
// a lower number, so it is checked where it happens: every second card of every line, on every layout of a
// few hundred random holdings.
g_overtake_line: Sd_Line
g_overtakes: int

@(test)
test_no_line_overtakes_a_winning_top_card :: proc(t: ^testing.T) {
	rand.reset(20261017)
	for _ in 0 ..< 300 {
		n, s := random_holding(5, 9)
		for line in candidate_lines() {
			g_overtake_line = line
			g_overtakes = 0
			watched := Sd_Line {
				name    = line.name,
				lead    = line.lead,
				partner = proc(v: Sd_View) -> int {
					r := g_overtake_line.partner(v)
					out := FULL_SUIT & ~(v.north | v.south | v.played)
					top := v.win_ns && top_card(v.win_rank, max(highest_rank(v.north | v.south), v.win_rank), out)
					if top && r > v.win_rank && lowest_rank(v.own) < v.win_rank {
						g_overtakes += 1
					}
					return r
				},
			}
			_ = sd_line_distribution(n, s, watched)
			testing.expectf(t, g_overtakes == 0, "%s overtakes a winning top card on %04x/%04x", line.name, n, s)
		}
		free_all(context.temp_allocator)
	}
}

// The memo is shared across every East-West split of one evaluation, keyed on the position (the four holdings,
// the trick, who has shown out). A line reading anything the key leaves out would take a position's value from
// another split, wrongly and silently - the show-outs had to join the key when `line_cash_then_discover` began
// reading them. So every line, on every split of a few hundred random holdings, takes the same tricks with the
// shared memo as with a fresh one.
@(test)
test_the_shared_memo_matches_a_fresh_one :: proc(t: ^testing.T) {
	rand.reset(20261018)
	for _ in 0 ..< 200 {
		n, s := random_holding(5, 10)
		missing := FULL_SUIT & ~(n | s)
		for line in candidate_lines() {
			memo := make(map[u64]int)
			defer delete(memo)
			it := split_iter_init(missing)
			for {
				east, _, _, ok := split_iter_next(&it)
				if !ok {
					break
				}
				shared := sd_deal_tricks(line, n, s, east, missing & ~east, &memo)
				fresh := sd_deal_tricks(line, n, s, east, missing & ~east)
				testing.expectf(t, shared == fresh, "%s on %04x/%04x, East %04x: %d with the shared memo, %d fresh", line.name, n, s, east, shared, fresh)
			}
		}
		free_all(context.temp_allocator)
	}
}

// A random holding of `lo`..`hi` cards split between the hands, both hands holding at least one.
@(private = "file")
random_holding :: proc(lo, hi: int) -> (north, south: u16) {
	for north == 0 || south == 0 {
		north, south = 0, 0
		perm := rand.perm(RANKS, context.temp_allocator)
		for k in 0 ..< lo + rand.int_max(hi - lo + 1) {
			if rand.int_max(2) == 0 {
				north |= rank_bit(perm[k])
			} else {
				south |= rank_bit(perm[k])
			}
		}
	}
	return
}

// THE RATCHET. Holdings with the best fixed line's mean and the EXACT single-dummy optimum, recorded on
// 2026-10-17 from a sweep of random holdings against `sd_optimal_distribution`: the biggest gains of the
// finesse repair, the biggest remaining gaps, and a random sample. The best fixed line may not fall below its
// recorded mean (a line got worse - find out why before re-recording) nor rise above the optimum (then the
// evaluator is wrong: no fixed line can beat the optimal search). Re-record with `just combo-line-sweep`, which
// also lists where the fixed lines fall furthest short - the work list for new lines.
@(test)
test_the_fixed_lines_hold_their_ground :: proc(t: ^testing.T) {
	Pinned :: struct {
		north, south: u16,
		fixed, opt:   f64,
	}
	pinned := []Pinned {
		{0x0080, 0x147e, 6.811304, 6.811304}, // 9 opposite AQ876543
		{0x0049, 0x1594, 5.000000, 5.031304}, // 852 opposite AQT964
		{0x02d0, 0x150a, 4.452174, 4.500000}, // J986 opposite AQT53
		{0x1660, 0x011a, 4.452174, 4.500000}, // AQJ87 opposite T653
		{0x160a, 0x0145, 4.452174, 4.452174}, // AQJ53 opposite T842
		{0x0110, 0x146d, 5.873478, 5.873478}, // T6 opposite AQ87542
		{0x174b, 0x0010, 7.265652, 7.265652}, // AQJT8532 opposite 6
		{0x0005, 0x0bd2, 5.452174, 5.452174}, // 42 opposite KJT9863
		{0x0023, 0x13c8, 4.760000, 4.760000},
		{0x0318, 0x00a6, 1.000000, 1.000000},
		{0x0223, 0x0958, 3.342174, 3.390000},
		{0x1a20, 0x0183, 3.500000, 3.528261},
		{0x1614, 0x00c9, 4.404348, 4.404348}, // AQJ64 opposite 9852: 0.32 short until finesse-high (2026-10-18)
		{0x1689, 0x0066, 5.500000, 5.500000}, // AQJ952 opposite 8743: likewise, 0.24
		{0x0202, 0x09c5, 4.367391, 4.367391}, // J3 opposite KT9842: 0.20 short until finesse-then-run (2026-10-18)
		{0x0502, 0x12c5, 5.500000, 5.500000}, // QT3 opposite AJ9842: likewise, 0.05
		{0x04e1, 0x120a, 4.280000, 4.327826}, // Q9872 opposite AJ53: likewise, 0.11 of 0.16
		{0x01c1, 0x0826, 1.771304, 1.827826},
		{0x040a, 0x0271, 2.175652, 2.353478},
		{0x1910, 0x02a8, 3.500000, 3.528261},
		{0x1901, 0x0286, 3.500000, 3.528261},
		{0x1114, 0x04c9, 3.827826, 3.890000},
		{0x0192, 0x0a4d, 4.520000, 4.630000},
		{0x0269, 0x1906, 4.890000, 4.890000},
		{0x0b84, 0x1033, 4.890000, 4.890000},
		{0x10ee, 0x0a01, 6.890000, 6.890000},
		{0x0a4d, 0x10b0, 5.890000, 5.890000}, // KJ8542 opposite A976: 0.11 short until cash-then-discover (2026-10-18)
		{0x028d, 0x0062, 1.800000, 1.819565},
		{0x14c8, 0x0924, 4.952174, 5.000000},
		{0x09be, 0x0041, 6.280000, 6.280000},
		{0x052d, 0x1812, 6.000000, 6.000000},
		{0x1920, 0x064a, 5.000000, 5.000000},
		{0x0aec, 0x0003, 5.150000, 5.217826},
		{0x07a0, 0x0808, 4.000000, 4.000000},
		{0x0002, 0x0ccd, 4.862174, 4.916087},
		{0x1221, 0x0598, 4.500000, 4.500000},
		{0x1b02, 0x004d, 4.579130, 4.579130},
		{0x1470, 0x0809, 4.639130, 4.658696},
		{0x1c81, 0x0368, 5.000000, 5.000000},
		{0x129c, 0x0d00, 6.000000, 6.000000},
		{0x1062, 0x070c, 4.452174, 4.452174},
		{0x15b1, 0x0a08, 7.000000, 7.000000},
		{0x0838, 0x0645, 3.904348, 3.952174},
		{0x08ec, 0x1301, 5.890000, 5.890000}, // K98754 opposite AJT2: cash-then-discover
		{0x1b50, 0x0087, 5.890000, 5.890000}, // AKJT86 opposite 9432: likewise
		{0x0cc1, 0x1128, 5.000000, 5.000000}, // KQ982 opposite AT75: likewise, 0.10
	}
	for p in pinned {
		got := expected_tricks(best_line_by_mean(p.north, p.south).dist.p)
		testing.expectf(t, got >= p.fixed - 1e-6, "%04x/%04x: the best fixed line fell to %.6f from %.6f", p.north, p.south, got, p.fixed)
		testing.expectf(t, got <= p.opt + 1e-6, "%04x/%04x: a fixed line %.6f beats the optimum %.6f", p.north, p.south, got, p.opt)
	}
}
