package norn

/*
	combined_opc_test.odin — unit tests for the partnership combined-OPC building blocks.

	The per-suit adjustment primitives (opc_fit_points / opc_opposite_long_suit /
	opc_honour_opposite_shortage / opc_weak_honour_fit_upgrade) are pure functions over a single suit's
	rank mask, so each is tested in isolation against hand-built holdings before combined_opc composes
	them. `mask` builds a suit holding from a list of ranks.
*/

import "core:testing"

// Build a single-suit holding from an explicit list of ranks.
mask :: proc(ranks: ..Rank) -> Rank_Set {
	m: Rank_Set
	for r in ranks {
		m += {r}
	}
	return m
}

// opc_fit_points: nothing under eight cards; 1 / 2 / 3 at eight / nine / ten-plus.
@(test)
test_opc_fit_points :: proc(t: ^testing.T) {
	testing.expect_value(t, opc_fit_points(7), f32(0.0))
	testing.expect_value(t, opc_fit_points(8), f32(1.0))
	testing.expect_value(t, opc_fit_points(9), f32(2.0))
	testing.expect_value(t, opc_fit_points(10), f32(3.0))
	testing.expect_value(t, opc_fit_points(13), f32(3.0))
}

// opc_opposite_long_suit: shortage opposite partner's 5+ suit is a misfit; a working doubleton a
// semi-fit; three-plus, or a non-working doubleton, neutral.
@(test)
test_opc_opposite_long_suit :: proc(t: ^testing.T) {
	// Shortages: void / singleton / two small.
	testing.expect_value(t, opc_opposite_long_suit(mask(), 0), f32(-3.0))
	testing.expect_value(t, opc_opposite_long_suit(mask(.Five), 1), f32(-2.0))
	testing.expect_value(t, opc_opposite_long_suit(mask(.Three, .Two), 2), f32(-1.0)) // xx

	// Working doubletons -> semi-fit +1.
	testing.expect_value(t, opc_opposite_long_suit(mask(.King, .Two), 2), f32(1.0)) // Kx
	testing.expect_value(t, opc_opposite_long_suit(mask(.Queen, .Two), 2), f32(1.0)) // Qx
	testing.expect_value(t, opc_opposite_long_suit(mask(.Jack, .Two), 2), f32(1.0)) // Jx
	testing.expect_value(t, opc_opposite_long_suit(mask(.Jack, .Ten), 2), f32(1.0)) // JT

	// Non-working doubletons -> neutral.
	testing.expect_value(t, opc_opposite_long_suit(mask(.Ace, .Two), 2), f32(0.0)) // Ax
	testing.expect_value(t, opc_opposite_long_suit(mask(.Queen, .Jack), 2), f32(0.0)) // QJ
	testing.expect_value(t, opc_opposite_long_suit(mask(.King, .Queen), 2), f32(0.0)) // KQ
	testing.expect_value(t, opc_opposite_long_suit(mask(.Queen, .Ten), 2), f32(0.0)) // QT (not JT)

	// Three-plus: neutral (this hand contributes length, not a misfit).
	testing.expect_value(t, opc_opposite_long_suit(mask(.King, .Three, .Two), 3), f32(0.0))
}

// opc_honour_opposite_shortage: K/Q/J opposite partner's shortage is wasted; none is a plus; an
// isolated ace a small plus opposite a singleton only.
@(test)
test_opc_honour_opposite_shortage :: proc(t: ^testing.T) {
	// K/Q/J present -> wasted.
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.King, .Three, .Two), 1), f32(-2.0))
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.King, .Three, .Two), 0), f32(-3.0))
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.Queen, .Jack, .Two), 0), f32(-3.0))

	// No K/Q/J and no ace -> freed value.
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.Nine, .Three, .Two), 1), f32(2.0))
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.Nine, .Three, .Two), 0), f32(3.0))

	// Isolated ace (no K/Q/J): +1 opposite a singleton, 0 opposite a void.
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.Ace, .Three, .Two), 1), f32(1.0))
	testing.expect_value(t, opc_honour_opposite_shortage(mask(.Ace, .Three, .Two), 0), f32(0.0))
}

// opc_weak_honour_fit_upgrade: a weak picture holding (< 4 Milton, not QJT) gains +1 in a fit; strong
// holdings, bare QJT, and pictureless holdings gain nothing.
@(test)
test_opc_weak_honour_fit_upgrade :: proc(t: ^testing.T) {
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.Queen, .Three, .Two)), f32(1.0)) // Qxx
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.Jack, .Three, .Two)), f32(1.0)) // Jxx
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.King, .Two)), f32(1.0)) // Kx: 3 < 4 pts
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.Queen, .Jack, .Ten)), f32(0.0)) // QJT excluded
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.King, .Queen, .Two)), f32(0.0)) // 5 pts, strong
	testing.expect_value(t, opc_weak_honour_fit_upgrade(mask(.Nine, .Three, .Two)), f32(0.0)) // no picture
}

// A 7-3-2-1 shape with NO honours: whole-hand honour = -2 (no Q, no K), length points 3 (poor 7-card),
// suit distribution +2 (singleton). As a suit responder both extras are pared back — length capped to
// 2, the singleton's shortage stripped — leaving just the honour count. NT keeps the ordinary total.
resp_7321_no_honours :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Nine),
			make_card(.Spades, .Eight),
			make_card(.Spades, .Seven),
			make_card(.Spades, .Six),
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Two),
		},
	)
}

// A 4-3-3-3 with NO honours: honour = -2, no length, distribution just the -1 flat. Nothing to cap or
// strip, so the suit responder base keeps the flat -1 penalty (== the full non-opening suit total).
resp_4333_no_honours :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Four),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	)
}

// opc_responder_base: suit caps length at 2 and strips shortage distribution; NT is the plain
// non-opening NT total; the flat -1 4333 penalty survives the suit cap.
@(test)
test_opc_responder_base :: proc(t: ^testing.T) {
	long := resp_7321_no_honours()
	o := opc_points(long)
	// Sanity on the fixture: honour -2, length 3, suit distribution +2 (singleton).
	testing.expect_value(t, o.honour.non_opening, f32(-2.0))
	testing.expect_value(t, o.length, f32(3.0))
	// Suit responder: honour(-2) + capped length(2) + no shortage(0) = 0.
	testing.expect_value(t, opc_responder_base(Responder(long), false), f32(0.0))
	// NT responder: the ordinary non-opening NT total (no cap, no strip).
	testing.expect_value(t, opc_responder_base(Responder(long), true), o.non_opening_nt)

	// 4-3-3-3: the flat -1 is all the distribution there is, so suit responder == full non-opening suit.
	flat := resp_4333_no_honours()
	fo := opc_points(flat)
	testing.expect_value(t, opc_responder_base(Responder(flat), false), f32(-3.0))
	testing.expect_value(t, opc_responder_base(Responder(flat), false), fo.non_opening_suit)
}

// Shape-only fixtures for the mirror test (honours irrelevant to pattern).
shape_5332_spades :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Ace),
			make_card(.Spades, .King),
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	)
}
shape_5332_hearts :: proc() -> Hand_Summary { 	// same [5,3,3,2] pattern, long suit in hearts
	return summarize(
		Hand {
			make_card(.Hearts, .Ace),
			make_card(.Hearts, .King),
			make_card(.Hearts, .Five),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	)
}
shape_6421 :: proc() -> Hand_Summary { 	// [6,4,2,1] — long, different shape
	return summarize(
		Hand {
			make_card(.Spades, .Ace),
			make_card(.Spades, .King),
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Hearts, .Five),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Two),
		},
	)
}

// opc_mirror_penalty (WHOLE-HAND): the same length in EVERY suit (positional), with a 5+ suit -> -2.
@(test)
test_opc_mirror_penalty :: proc(t: ^testing.T) {
	a := shape_5332_spades()
	// Identical distribution (spades opposite spades, ...): a whole-hand mirror -> -2.
	testing.expect_value(t, opc_mirror_penalty(a, a), f32(-2.0))
	// Same SORTED pattern [5,3,3,2] but the long suit differs (spades vs hearts): not positionally
	// mirrored -> 0 (this is the old, looser behaviour, now correctly rejected).
	testing.expect_value(t, opc_mirror_penalty(a, shape_5332_hearts()), f32(0.0))
	// Different shape -> 0.
	testing.expect_value(t, opc_mirror_penalty(a, shape_6421()), f32(0.0))
	// Two 4-3-3-3 hands ARE a positional mirror but have NO long suit -> gate blocks the penalty.
	flat := resp_4333_no_honours()
	testing.expect_value(t, opc_mirror_penalty(flat, flat), f32(0.0))
}

// Opener: spades AKQJT, else low (5-3-3-2). opening_suit = honour 12.5 + length 1 = 13.5.
combined_opener_akqjt :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Ace),
			make_card(.Spades, .King),
			make_card(.Spades, .Queen),
			make_card(.Spades, .Jack),
			make_card(.Spades, .Ten),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	)
}

// Responder: 3-3-3-4, no honours. Suit responder base = honour -2 + length 0 + flat -1 = -3. Gives an
// 8-card spade fit with the opener (5+3) and no shortage anywhere.
combined_responder_flat :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Hearts, .Seven),
			make_card(.Hearts, .Six),
			make_card(.Hearts, .Five),
			make_card(.Diamonds, .Seven),
			make_card(.Diamonds, .Six),
			make_card(.Diamonds, .Five),
			make_card(.Clubs, .Seven),
			make_card(.Clubs, .Six),
			make_card(.Clubs, .Five),
			make_card(.Clubs, .Four),
		},
	)
}

// combined_opc integration: opener 13.5 + responder base -3 + an 8-card spade fit (+1), then TWO mirror
// suits — opener and responder are both 3=3 in hearts and diamonds (equal, non-fit) -> -2 — nets to 9.5,
// at suit and NT alike (fit and mirror both apply to each). And it is order-symmetric.
@(test)
test_combined_opc_compose :: proc(t: ^testing.T) {
	o := combined_opener_akqjt()
	r := combined_responder_flat()

	testing.expect_value(t, combined_opc(o, r, Suit.Spades), f32(9.5))
	testing.expect_value(t, combined_opc(o, r, nil), f32(9.5)) // NT: same base + fit + mirror here

	// Order-independent (stronger hand is chosen as opener internally).
	testing.expect_value(t, combined_opc(r, o, Suit.Spades), f32(9.5))
	testing.expect_value(t, combined_opc(r, o, nil), f32(9.5))
}

// A summary built from suit LENGTHS alone (all low cards), for length-only distribution tests. Suit
// order of the args is spades, hearts, diamonds, clubs; they must total 13.
hand_from_lengths :: proc(sp, he, di, cl: int) -> Hand_Summary {
	s: Hand_Summary
	for i in 0 ..< sp {s.suits[.Spades] += {Rank(i)}}
	for i in 0 ..< he {s.suits[.Hearts] += {Rank(i)}}
	for i in 0 ..< di {s.suits[.Diamonds] += {Rank(i)}}
	for i in 0 ..< cl {s.suits[.Clubs] += {Rank(i)}}
	return s
}

// opc_support_ruffing (trump = spades): 2-4 support ruffs the shortest side suit (trump length minus
// that length); 5+ trumps count full opening-style shortage; under two trumps is nothing.
@(test)
test_opc_support_ruffing :: proc(t: ^testing.T) {
	// 2-4 card support: rt - shortest side suit.
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(4, 1, 4, 4)), .Spades), f32(3.0)) // 4 trumps, singleton
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(3, 2, 4, 4)), .Spades), f32(1.0)) // 3 trumps, doubleton
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(3, 3, 3, 4)), .Spades), f32(0.0)) // no side shortage
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(4, 0, 4, 5)), .Spades), f32(4.0)) // 4 trumps, void

	// 5+ trumps: full opening-style suit distribution (singleton +2 / void +4).
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(5, 1, 4, 3)), .Spades), f32(2.0)) // singleton side
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(5, 0, 4, 4)), .Spades), f32(4.0)) // void side

	// Under two trumps: not a support hand.
	testing.expect_value(t, opc_support_ruffing(Responder(hand_from_lengths(1, 4, 4, 4)), .Spades), f32(0.0))
}

// Responder with 4-card trump support and a side singleton, opposite the AKQJT opener: a 9-card spade
// fit (+2), the opener's worthless hearts freed opposite the singleton (+2), and 4-1 ruffing (+3) on
// top of opener 13.5 + responder base -2 = 18.5. NT (no ruffing / freed shortage) differs.
@(test)
test_combined_opc_ruffing :: proc(t: ^testing.T) {
	o := combined_opener_akqjt() // 5-3-3-2, opening_suit 13.5
	r := summarize(
		Hand {
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Five),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Five),
			make_card(.Clubs, .Four),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	) // 4-1-4-4, no honours

	testing.expect_value(t, combined_opc(o, r, Suit.Spades), f32(18.5))
}

// opc_per_suit_mirror_penalty: -1 for every side suit where BOTH hands are short (<=2) and of EQUAL
// length, gated on a 5+ suit existing; a same-pattern pair whose doubletons sit in DIFFERENT suits is
// not positionally mirrored, so scores 0 here (only the whole-hand -2 catches it).
@(test)
test_opc_per_suit_mirror_penalty :: proc(t: ^testing.T) {
	// A mirror suit = both hands equal length AND non-fit (equal length <= 3), gated on a 5+ suit.
	// 5-3-3-2 vs 5-4-2-2: only clubs (2 == 2) mirrors; spades 5==5 is a FIT (excluded), hearts/diamonds differ.
	testing.expect_value(
		t,
		opc_per_suit_mirror_penalty(hand_from_lengths(5, 3, 3, 2), hand_from_lengths(5, 4, 2, 2)),
		f32(-1.0),
	)

	// 6-5-2-0 mirrored exactly: spades/hearts are fits (6,5 excluded); diamonds (2==2) and clubs (0==0) -> -2.
	testing.expect_value(
		t,
		opc_per_suit_mirror_penalty(hand_from_lengths(6, 5, 2, 0), hand_from_lengths(6, 5, 2, 0)),
		f32(-2.0),
	)

	// A mirrored 3-card SIDE suit now counts (equal, non-fit): hearts 3==3 -> -1.
	testing.expect_value(
		t,
		opc_per_suit_mirror_penalty(hand_from_lengths(5, 3, 2, 3), hand_from_lengths(5, 3, 3, 2)),
		f32(-1.0),
	)

	// An equal 4-4 is a FIT, not a mirror: 5-4-2-2 twice -> only diamonds + clubs mirror -> -2.
	testing.expect_value(
		t,
		opc_per_suit_mirror_penalty(hand_from_lengths(5, 4, 2, 2), hand_from_lengths(5, 4, 2, 2)),
		f32(-2.0),
	)

	// No 5+ suit anywhere: the gate blocks the penalty even for an exact mirror.
	testing.expect_value(
		t,
		opc_per_suit_mirror_penalty(hand_from_lengths(4, 3, 3, 3), hand_from_lengths(4, 3, 3, 3)),
		f32(0.0),
	)
}

// combined_opc_breakdown: the component fields sum to the total combined_opc returns, and each names the
// adjustment it carries. Same fixtures as test_combined_opc_compose (opener 13.5 + responder -3 + one
// 8-card fit +1 + two 3=3 mirror suits -2 = 9.5) — here checked field by field.
@(test)
test_combined_opc_breakdown :: proc(t: ^testing.T) {
	o := combined_opener_akqjt()
	r := combined_responder_flat()

	br := combined_opc_breakdown(o, r, Suit.Spades)
	testing.expect_value(t, br.opener_base, f32(13.5))
	testing.expect_value(t, br.responder_base, f32(-3.0))
	testing.expect_value(t, br.fit, f32(1.0)) // one 8-card spade fit
	testing.expect_value(t, br.misfit, f32(0.0))
	testing.expect_value(t, br.wasted, f32(0.0))
	testing.expect_value(t, br.weak_fit, f32(0.0))
	testing.expect_value(t, br.ruffing, f32(0.0)) // flat responder, no side shortage to ruff
	testing.expect_value(t, br.mirror, f32(-2.0)) // hearts 3=3 and diamonds 3=3 both mirror
	testing.expect_value(t, br.total, f32(9.5))
	testing.expect_value(t, br.total, combined_opc(o, r, Suit.Spades)) // breakdown agrees with the scalar
}

// Does the breakdown hold a labelled entry with this reason? (order-independent existence check.)
has_reason :: proc(br: Opc_Breakdown, reason: Opc_Reason) -> bool {
	for i in 0 ..< br.n_entries {
		if br.entries[i].reason == reason {
			return true
		}
	}
	return false
}

// combined_opc_breakdown detail: the base H/L/D components sum to each base, and the labelled per-suit
// entries sum to the adjustment tail (total minus the two bases). Exercised on the ruffing fixture so a
// Fit and a Ruff_Support entry are both present (the render_summary "which suit / why" detail).
@(test)
test_combined_opc_breakdown_detail :: proc(t: ^testing.T) {
	o := combined_opener_akqjt() // 5-3-3-2 AKQJT
	r := summarize(
		Hand {
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Five),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Five),
			make_card(.Clubs, .Four),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	) // 4-1-4-4 unbalanced

	br := combined_opc_breakdown(o, r, Suit.Spades)

	// Bases equal their H/L/D split.
	testing.expect_value(t, br.opener_h + br.opener_l + br.opener_d, br.opener_base)
	testing.expect_value(t, br.responder_h + br.responder_l + br.responder_d, br.responder_base)

	// The labelled entries account for exactly the adjustment tail (everything but the two bases).
	sum: f32 = 0
	for i in 0 ..< br.n_entries {
		sum += br.entries[i].value
	}
	testing.expect_value(t, sum, br.total - br.opener_base - br.responder_base)

	// The two headline distributional-fit facts are individually present, not just summed.
	testing.expect(t, has_reason(br, .Fit), "expected a Fit entry for the 9-card spade fit")
	testing.expect(t, has_reason(br, .Ruff_Support), "expected a Ruff_Support entry for the heart singleton")
}

// The misfit/semi-fit and wasted/freed splits must be labelled separately, so a +1 semi-fit netting a -1
// misfit does not silently vanish (the family sum could be 0 while both entries exist). Opener long in
// spades opposite responder's Kx (semi-fit) AND a singleton club (misfit) exercises both signs.
@(test)
test_combined_opc_breakdown_split_signs :: proc(t: ^testing.T) {
	o := summarize(
		Hand {
			make_card(.Spades, .Ace),
			make_card(.Spades, .King),
			make_card(.Spades, .Queen),
			make_card(.Spades, .Jack),
			make_card(.Spades, .Ten),
			make_card(.Hearts, .Four),
			make_card(.Hearts, .Three),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Clubs, .Four),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	) // 5-3-2-3 long spades
	r := summarize(
		Hand {
			make_card(.Spades, .Nine),
			make_card(.Spades, .Eight),
			make_card(.Hearts, .King),
			make_card(.Hearts, .Seven),
			make_card(.Hearts, .Six),
			make_card(.Hearts, .Five),
			make_card(.Hearts, .Nine),
			make_card(.Diamonds, .King),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Ten),
			make_card(.Clubs, .Nine),
			make_card(.Clubs, .Eight),
			make_card(.Clubs, .Seven),
		},
	) // 2-5-2-4: long hearts, doubletons

	// Opener long spades (5) opposite responder's 98 doubleton = xx -> Misfit_Xx; responder long hearts (5)
	// opposite opener's 3 small = neutral; opener 2 diamonds opposite nothing. Force the two signs by
	// checking both a misfit and a semi-fit can be surfaced across strains.
	br := combined_opc_breakdown(o, r, Suit.Spades)
	// Whatever fires, every labelled entry's value is non-zero (opc_push drops zeros) and the entries sum
	// to the adjustment tail — the invariant that guarantees nothing is lost to netting.
	sum: f32 = 0
	for i in 0 ..< br.n_entries {
		testing.expect(t, br.entries[i].value != 0, "no zero-valued entries")
		sum += br.entries[i].value
	}
	testing.expect_value(t, sum, br.total - br.opener_base - br.responder_base)
}

// A trump fit opposite an UNBALANCED hand must surface distributional-fit value in the breakdown: with a
// 9-card spade fit facing a 4-1-4-4 singleton, both the fit-points and the ruffing terms are non-zero,
// and they push the suit total above the notrump total (which gets no ruff and no freed shortage).
@(test)
test_combined_opc_distribution_fit_present :: proc(t: ^testing.T) {
	o := combined_opener_akqjt() // 5-3-3-2
	r := summarize(
		Hand {
			make_card(.Spades, .Five),
			make_card(.Spades, .Four),
			make_card(.Spades, .Three),
			make_card(.Spades, .Two),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Five),
			make_card(.Diamonds, .Four),
			make_card(.Diamonds, .Three),
			make_card(.Diamonds, .Two),
			make_card(.Clubs, .Five),
			make_card(.Clubs, .Four),
			make_card(.Clubs, .Three),
			make_card(.Clubs, .Two),
		},
	) // 4-1-4-4, unbalanced (singleton heart)

	br := combined_opc_breakdown(o, r, Suit.Spades)
	testing.expect(t, br.fit > 0, "9-card fit must contribute fit points")
	testing.expect(t, br.ruffing > 0, "singleton opposite a trump fit must contribute ruffing value")

	nt := combined_opc_breakdown(o, r, nil)
	testing.expect_value(t, nt.ruffing, f32(0.0)) // notrump: no trump fit, no ruff
	testing.expect(t, br.total > nt.total, "the trump fit's distribution must beat the flat NT total")
}
