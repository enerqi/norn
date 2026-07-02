package norn

/*
	combined_opc_test.odin — unit tests for the partnership combined-OPC building blocks.

	The per-suit adjustment primitives (opc_fit_points / opc_opposite_long_suit /
	opc_honour_opposite_shortage / opc_weak_honour_fit_upgrade) are pure functions over a single suit's
	rank mask, so each is tested in isolation against hand-built holdings before combined_opc composes
	them. `mask` builds a suit holding from a list of ranks.
*/

import "core:testing"

// Build a single-suit rank mask (bit r set per rank) from an explicit list of ranks.
mask :: proc(ranks: ..Rank) -> u16 {
	m: u16
	for r in ranks {
		m |= u16(1) << u16(r)
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
	testing.expect_value(t, opc_responder_base(long, false), f32(0.0))
	// NT responder: the ordinary non-opening NT total (no cap, no strip).
	testing.expect_value(t, opc_responder_base(long, true), o.non_opening_nt)

	// 4-3-3-3: the flat -1 is all the distribution there is, so suit responder == full non-opening suit.
	flat := resp_4333_no_honours()
	fo := opc_points(flat)
	testing.expect_value(t, opc_responder_base(flat, false), f32(-3.0))
	testing.expect_value(t, opc_responder_base(flat, false), fo.non_opening_suit)
}

// Shape-only fixtures for the mirror test (honours irrelevant to pattern).
shape_5332_spades :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Ace), make_card(.Spades, .King), make_card(.Spades, .Five),
			make_card(.Spades, .Four), make_card(.Spades, .Three),
			make_card(.Hearts, .Four), make_card(.Hearts, .Three), make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four), make_card(.Diamonds, .Three), make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three), make_card(.Clubs, .Two),
		},
	)
}
shape_5332_hearts :: proc() -> Hand_Summary { 	// same [5,3,3,2] pattern, long suit in hearts
	return summarize(
		Hand {
			make_card(.Hearts, .Ace), make_card(.Hearts, .King), make_card(.Hearts, .Five),
			make_card(.Hearts, .Four), make_card(.Hearts, .Three),
			make_card(.Spades, .Four), make_card(.Spades, .Three), make_card(.Spades, .Two),
			make_card(.Diamonds, .Four), make_card(.Diamonds, .Three), make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three), make_card(.Clubs, .Two),
		},
	)
}
shape_6421 :: proc() -> Hand_Summary { 	// [6,4,2,1] — long, different shape
	return summarize(
		Hand {
			make_card(.Spades, .Ace), make_card(.Spades, .King), make_card(.Spades, .Five),
			make_card(.Spades, .Four), make_card(.Spades, .Three), make_card(.Spades, .Two),
			make_card(.Hearts, .Five), make_card(.Hearts, .Four), make_card(.Hearts, .Three), make_card(.Hearts, .Two),
			make_card(.Diamonds, .Three), make_card(.Diamonds, .Two),
			make_card(.Clubs, .Two),
		},
	)
}

// opc_mirror_penalty: identical shapes with a long suit -> -2; differing shapes or no long suit -> 0.
@(test)
test_opc_mirror_penalty :: proc(t: ^testing.T) {
	a := shape_5332_spades()
	b := shape_5332_hearts()
	testing.expect_value(t, opc_mirror_penalty(a, b), f32(-2.0)) // mirror [5,3,3,2] both, long suits

	testing.expect_value(t, opc_mirror_penalty(a, shape_6421()), f32(0.0)) // different shapes

	// Two 4-3-3-3 hands are a mirror but have NO long suit -> gate blocks the penalty.
	flat := resp_4333_no_honours()
	testing.expect_value(t, opc_mirror_penalty(flat, flat), f32(0.0))
}

// Opener: spades AKQJT, else low (5-3-3-2). opening_suit = honour 12.5 + length 1 = 13.5.
combined_opener_akqjt :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Ace), make_card(.Spades, .King), make_card(.Spades, .Queen),
			make_card(.Spades, .Jack), make_card(.Spades, .Ten),
			make_card(.Hearts, .Four), make_card(.Hearts, .Three), make_card(.Hearts, .Two),
			make_card(.Diamonds, .Four), make_card(.Diamonds, .Three), make_card(.Diamonds, .Two),
			make_card(.Clubs, .Three), make_card(.Clubs, .Two),
		},
	)
}

// Responder: 3-3-3-4, no honours. Suit responder base = honour -2 + length 0 + flat -1 = -3. Gives an
// 8-card spade fit with the opener (5+3) and no shortage anywhere.
combined_responder_flat :: proc() -> Hand_Summary {
	return summarize(
		Hand {
			make_card(.Spades, .Five), make_card(.Spades, .Four), make_card(.Spades, .Three),
			make_card(.Hearts, .Seven), make_card(.Hearts, .Six), make_card(.Hearts, .Five),
			make_card(.Diamonds, .Seven), make_card(.Diamonds, .Six), make_card(.Diamonds, .Five),
			make_card(.Clubs, .Seven), make_card(.Clubs, .Six), make_card(.Clubs, .Five), make_card(.Clubs, .Four),
		},
	)
}

// combined_opc integration: opener 13.5 + responder base -3 + a single 8-card fit (+1), no other
// adjustment = 11.5, at suit and NT alike (fit points apply to both). And it is order-symmetric.
@(test)
test_combined_opc_compose :: proc(t: ^testing.T) {
	o := combined_opener_akqjt()
	r := combined_responder_flat()

	testing.expect_value(t, combined_opc(o, r, Suit.Spades), f32(11.5))
	testing.expect_value(t, combined_opc(o, r, nil), f32(11.5)) // NT: same base + fit here

	// Order-independent (stronger hand is chosen as opener internally).
	testing.expect_value(t, combined_opc(r, o, Suit.Spades), f32(11.5))
	testing.expect_value(t, combined_opc(r, o, nil), f32(11.5))
}

// A summary built from suit LENGTHS alone (all low cards), for length-only distribution tests. Suit
// order of the args is spades, hearts, diamonds, clubs; they must total 13.
hand_from_lengths :: proc(sp, he, di, cl: int) -> Hand_Summary {
	s: Hand_Summary
	for i in 0 ..< sp {s.suits[.Spades] |= u16(1) << u16(i)}
	for i in 0 ..< he {s.suits[.Hearts] |= u16(1) << u16(i)}
	for i in 0 ..< di {s.suits[.Diamonds] |= u16(1) << u16(i)}
	for i in 0 ..< cl {s.suits[.Clubs] |= u16(1) << u16(i)}
	return s
}

// opc_support_ruffing (trump = spades): 2-4 support ruffs the shortest side suit (trump length minus
// that length); 5+ trumps count full opening-style shortage; under two trumps is nothing.
@(test)
test_opc_support_ruffing :: proc(t: ^testing.T) {
	// 2-4 card support: rt - shortest side suit.
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(4, 1, 4, 4), .Spades), f32(3.0)) // 4 trumps, singleton
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(3, 2, 4, 4), .Spades), f32(1.0)) // 3 trumps, doubleton
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(3, 3, 3, 4), .Spades), f32(0.0)) // no side shortage
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(4, 0, 4, 5), .Spades), f32(4.0)) // 4 trumps, void

	// 5+ trumps: full opening-style suit distribution (singleton +2 / void +4).
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(5, 1, 4, 3), .Spades), f32(2.0)) // singleton side
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(5, 0, 4, 4), .Spades), f32(4.0)) // void side

	// Under two trumps: not a support hand.
	testing.expect_value(t, opc_support_ruffing(hand_from_lengths(1, 4, 4, 4), .Spades), f32(0.0))
}

// Responder with 4-card trump support and a side singleton, opposite the AKQJT opener: a 9-card spade
// fit (+2), the opener's worthless hearts freed opposite the singleton (+2), and 4-1 ruffing (+3) on
// top of opener 13.5 + responder base -2 = 18.5. NT (no ruffing / freed shortage) differs.
@(test)
test_combined_opc_ruffing :: proc(t: ^testing.T) {
	o := combined_opener_akqjt() // 5-3-3-2, opening_suit 13.5
	r := summarize(
		Hand {
			make_card(.Spades, .Five), make_card(.Spades, .Four), make_card(.Spades, .Three), make_card(.Spades, .Two),
			make_card(.Hearts, .Two),
			make_card(.Diamonds, .Five), make_card(.Diamonds, .Four), make_card(.Diamonds, .Three), make_card(.Diamonds, .Two),
			make_card(.Clubs, .Five), make_card(.Clubs, .Four), make_card(.Clubs, .Three), make_card(.Clubs, .Two),
		},
	) // 4-1-4-4, no honours

	testing.expect_value(t, combined_opc(o, r, Suit.Spades), f32(18.5))
}
