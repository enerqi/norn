package norn

/*
	evaluate_test.odin — unit tests for the hand evaluation primitives.

	Hands are built explicitly so the expected evaluations are known exactly.
*/

import "core:testing"

// A balanced 4-3-3-3: spades A K Q J, hearts/diamonds/clubs low. 10 hcp, 3 controls.
balanced_4333 :: proc() -> Hand {
	return Hand {
		make_card(.Spades, .Ace),
		make_card(.Spades, .King),
		make_card(.Spades, .Queen),
		make_card(.Spades, .Jack),
		make_card(.Hearts, .Two),
		make_card(.Hearts, .Three),
		make_card(.Hearts, .Four),
		make_card(.Diamonds, .Two),
		make_card(.Diamonds, .Three),
		make_card(.Diamonds, .Four),
		make_card(.Clubs, .Two),
		make_card(.Clubs, .Three),
		make_card(.Clubs, .Four),
	}
}

// A 5-4-2-2: spades A K Q J T, hearts A K Q J, diamonds/clubs low. 20 hcp.
two_suiter_5422 :: proc() -> Hand {
	return Hand {
		make_card(.Spades, .Ace),
		make_card(.Spades, .King),
		make_card(.Spades, .Queen),
		make_card(.Spades, .Jack),
		make_card(.Spades, .Ten),
		make_card(.Hearts, .Ace),
		make_card(.Hearts, .King),
		make_card(.Hearts, .Queen),
		make_card(.Hearts, .Jack),
		make_card(.Diamonds, .Two),
		make_card(.Diamonds, .Three),
		make_card(.Clubs, .Two),
		make_card(.Clubs, .Three),
	}
}

// A 7-2-2-2: seven spades, two of each other suit.
unbalanced_7222 :: proc() -> Hand {
	return Hand {
		make_card(.Spades, .Ace),
		make_card(.Spades, .King),
		make_card(.Spades, .Queen),
		make_card(.Spades, .Jack),
		make_card(.Spades, .Ten),
		make_card(.Spades, .Nine),
		make_card(.Spades, .Eight),
		make_card(.Hearts, .Two),
		make_card(.Hearts, .Three),
		make_card(.Diamonds, .Two),
		make_card(.Diamonds, .Three),
		make_card(.Clubs, .Two),
		make_card(.Clubs, .Three),
	}
}

@(test)
test_suit_length :: proc(t: ^testing.T) {
	hand := two_suiter_5422()
	testing.expect_value(t, suit_length(hand, .Spades), 5)
	testing.expect_value(t, suit_length(hand, .Hearts), 4)
	testing.expect_value(t, suit_length(hand, .Diamonds), 2)
	testing.expect_value(t, suit_length(hand, .Clubs), 2)
	// The named shortcuts agree with the general primitive.
	testing.expect_value(t, spade_length(hand), 5)
	testing.expect_value(t, heart_length(hand), 4)
	testing.expect_value(t, diamond_length(hand), 2)
	testing.expect_value(t, club_length(hand), 2)
}

@(test)
test_hcp :: proc(t: ^testing.T) {
	testing.expect_value(t, hcp(balanced_4333()), 10) // A K Q J in spades
	testing.expect_value(t, hcp(two_suiter_5422()), 20) // AKQJ in two suits
}

@(test)
test_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, controls(balanced_4333()), 3) // spade A(2)+K(1)
	testing.expect_value(t, controls(two_suiter_5422()), 6) // two suits of A(2)+K(1)
}

@(test)
test_holds_and_top_count :: proc(t: ^testing.T) {
	hand := balanced_4333()
	testing.expect(t, holds(hand, .Spades, .Ace), "should hold the spade ace")
	testing.expect(t, !holds(hand, .Hearts, .Ace), "should not hold the heart ace")
	testing.expect_value(t, top_count(hand, .Spades, 4), 4) // A K Q J present
	testing.expect_value(t, top_count(hand, .Spades, 2), 2) // A K present
	testing.expect_value(t, top_count(hand, .Hearts, 5), 0) // no heart honours
}

@(test)
test_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, shape(two_suiter_5422()), [SUIT_COUNT]int{5, 4, 2, 2})
	testing.expect_value(t, shape(balanced_4333()), [SUIT_COUNT]int{4, 3, 3, 3})
}

@(test)
test_pattern_is_sorted_descending :: proc(t: ^testing.T) {
	// Spades is the long suit, but pattern is suit-agnostic and sorted high-to-low.
	testing.expect_value(t, pattern(two_suiter_5422()), [SUIT_COUNT]int{5, 4, 2, 2})
	testing.expect_value(t, pattern(unbalanced_7222()), [SUIT_COUNT]int{7, 2, 2, 2})
}

@(test)
test_is_balanced :: proc(t: ^testing.T) {
	testing.expect(t, is_balanced(balanced_4333()), "4-3-3-3 is balanced")
	testing.expect(t, !is_balanced(two_suiter_5422()), "5-4-2-2 is not balanced")
	testing.expect(t, !is_balanced(unbalanced_7222()), "7-2-2-2 is not balanced")
}

@(test)
test_is_semibalanced :: proc(t: ^testing.T) {
	testing.expect(t, is_semibalanced(balanced_4333()), "4-3-3-3 is semi-balanced")
	testing.expect(t, is_semibalanced(two_suiter_5422()), "5-4-2-2 is semi-balanced")
	testing.expect(t, !is_semibalanced(unbalanced_7222()), "7-2-2-2 is not semi-balanced")
}

// A 5-3-3-2 with five spades: spades A K x x x, hearts/diamonds three each, clubs a doubleton.
balanced_5332 :: proc() -> Hand {
	return Hand {
		make_card(.Spades, .Ace),
		make_card(.Spades, .King),
		make_card(.Spades, .Two),
		make_card(.Spades, .Three),
		make_card(.Spades, .Four),
		make_card(.Hearts, .Two),
		make_card(.Hearts, .Three),
		make_card(.Hearts, .Four),
		make_card(.Diamonds, .Two),
		make_card(.Diamonds, .Three),
		make_card(.Diamonds, .Four),
		make_card(.Clubs, .Two),
		make_card(.Clubs, .Three),
	}
}

@(test)
test_is_nt5cM_shape :: proc(t: ^testing.T) {
	testing.expect(t, is_nt5cM_shape(balanced_4333()), "4-3-3-3 is a 5CM_nt shape")
	testing.expect(t, is_nt5cM_shape(balanced_5332()), "5-3-3-2 is a 5CM_nt shape")
	testing.expect(t, !is_nt5cM_shape(two_suiter_5422()), "5-4-2-2 is not (it is a 5-4)")
	testing.expect(t, !is_nt5cM_shape(unbalanced_7222()), "7-2-2-2 is not (6+ suit)")
}

@(test)
test_losers :: proc(t: ^testing.T) {
	// Half-losers (deal's units). spades AKQJ = 0, three low tripletons = 6 each.
	testing.expect_value(t, losers(balanced_4333()), 18)
	// spades AKQJT = 0, hearts AKQJ = 0, two low doubletons = 4 each.
	testing.expect_value(t, losers(two_suiter_5422()), 8)
	// spades AKQ.. = 0, three low doubletons = 4 each.
	testing.expect_value(t, losers(unbalanced_7222()), 12)
}

@(test)
test_offense :: proc(t: ^testing.T) {
	// Solid five (AKQJT) -> full length.
	testing.expect_value(t, offense(two_suiter_5422(), .Spades), 5)
	// AKQJ-only four -> still full length (just makes the 100 cutoff).
	testing.expect_value(t, offense(balanced_4333(), .Spades), 4)
	// AKQ in a seven-bagger -> full length.
	testing.expect_value(t, offense(unbalanced_7222(), .Spades), 7)
	// A ragged low doubleton -> no offensive tricks.
	testing.expect_value(t, offense(two_suiter_5422(), .Diamonds), 0)
	// A low tripleton -> no offensive tricks.
	testing.expect_value(t, offense(balanced_4333(), .Hearts), 0)
}

@(test)
test_top5q :: proc(t: ^testing.T) {
	testing.expect_value(t, top5q(balanced_4333(), .Spades), 7) // A K Q J = 2+2+2+1
	testing.expect_value(t, top5q(two_suiter_5422(), .Spades), 8) // A K Q J T = 2+2+2+1+1
	testing.expect_value(t, top5q(balanced_4333(), .Hearts), 0) // no honours
}

// is_nt: balanced and in the hcp band. A 4-3-3-3 with 10 hcp is a 10-12 notrump but not an 11-13;
// a 5-4-2-2 is never a notrump (unbalanced) even with the points in range.
@(test)
test_is_nt :: proc(t: ^testing.T) {
	testing.expect(t, is_nt(balanced_4333(), 10, 12), "4333 with 10 hcp is a 10-12 NT")
	testing.expect(t, !is_nt(balanced_4333(), 11, 13), "4333 with 10 hcp is below an 11-13 NT")
	testing.expect(t, !is_nt(two_suiter_5422(), 0, 40), "a 5-4-2-2 is never balanced/NT")

	// A 5-3-3-2 with a five-card MINOR is balanced (only 5-card majors are excluded), so it is a
	// notrump shape; the same 5-3-3-2 with the five-bagger a MAJOR is not.
	testing.expect(t, is_nt(hand_from_shape({3, 3, 2, 5}), 0, 40), "5-3-3-2 with 5 clubs is a NT shape")
	testing.expect(t, is_nt(hand_from_shape({2, 3, 5, 3}), 0, 40), "5-3-3-2 with 5 diamonds is a NT shape")
	testing.expect(t, !is_nt(hand_from_shape({5, 3, 3, 2}), 0, 40), "5-3-3-2 with 5 spades is not balanced")
	testing.expect(t, !is_nt(hand_from_shape({3, 5, 3, 2}), 0, 40), "5-3-3-2 with 5 hearts is not balanced")
}

// Build a representative hand of a given s-h-d-c shape, filling each suit with its lowest cards.
// Lengths must sum to 13. Suitable for shape/pattern tests where only the lengths matter.
hand_from_shape :: proc(shape: [SUIT_COUNT]int) -> Hand {
	hand: Hand
	n := 0
	suits := [SUIT_COUNT]Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	for suit, i in suits {
		for r in 0 ..< shape[i] {
			hand[n] = make_card(suit, Rank(r))
			n += 1
		}
	}
	return hand
}

// The four longest-suit shape classes must PARTITION every hand: each of the 560 s-h-d-c
// compositions matches exactly one (majors gate on 5+, the minors catch the rest).
@(test)
test_longest_suit_shapes_partition :: proc(t: ^testing.T) {
	all, count := enumerate_shapes()
	for i in 0 ..< count {
		shape := all[i]
		hand := hand_from_shape(shape)
		matches := 0
		if is_spade_shape(hand) {matches += 1}
		if is_heart_shape(hand) {matches += 1}
		if is_diamond_shape(hand) {matches += 1}
		if is_club_shape(hand) {matches += 1}

		testing.expectf(t, matches == 1, "shape %v: %d classes matched, expected exactly 1", shape, matches)
	}
}

// Spot checks against the named fixtures, with the tie-break behaviour spelled out.
@(test)
test_longest_suit_shapes_spot :: proc(t: ^testing.T) {
	// 5-4-2-2 spades: a spade shape (spades longest).
	testing.expect(t, is_spade_shape(two_suiter_5422()), "5422 spades is a spade shape")
	testing.expect(t, !is_heart_shape(two_suiter_5422()), "5422 spades is not a heart shape")

	// 7-2-2-2 spades: a spade shape.
	testing.expect(t, is_spade_shape(unbalanced_7222()), "7222 spades is a spade shape")

	// 4-3-3-3: a four-card major doesn't qualify (majors gate on 5+), so it falls to the minor
	// catch-all — here a club shape.
	testing.expect(t, !is_spade_shape(balanced_4333()), "4333's 4-card major is not a spade shape")
	testing.expect(t, is_club_shape(balanced_4333()), "4333 falls to the club catch-all")

	// 5-5 majors resolves to spades; 5 hearts over 4 spades resolves to hearts.
	testing.expect(t, is_spade_shape(hand_from_shape({5, 5, 2, 1})), "5-5 majors is a spade shape")
	testing.expect(t, is_heart_shape(hand_from_shape({4, 5, 2, 2})), "5 hearts over 4 spades is a heart shape")

	// Long minors: a diamond shape and a club shape; equal 5-5 minors resolves to diamonds.
	testing.expect(t, is_diamond_shape(hand_from_shape({2, 2, 6, 3})), "6 diamonds is a diamond shape")
	testing.expect(t, is_club_shape(hand_from_shape({2, 2, 3, 6})), "6 clubs is a club shape")
	testing.expect(t, is_diamond_shape(hand_from_shape({2, 1, 5, 5})), "5-5 minors resolves to diamonds")
}

// A hand with known evaluations across every ported metric. Spades A K Q J T 9 8 (7),
// hearts A K (2), diamonds Q (1, the short honour), clubs 5 4 3 (3). 19 hcp.
eval_sampler :: proc() -> Hand {
	return Hand {
		make_card(.Spades, .Ace),
		make_card(.Spades, .King),
		make_card(.Spades, .Queen),
		make_card(.Spades, .Jack),
		make_card(.Spades, .Ten),
		make_card(.Spades, .Nine),
		make_card(.Spades, .Eight),
		make_card(.Hearts, .Ace),
		make_card(.Hearts, .King),
		make_card(.Diamonds, .Queen),
		make_card(.Clubs, .Five),
		make_card(.Clubs, .Four),
		make_card(.Clubs, .Three),
	}
}

// top_count now reaches 6 and 7 (A K Q J T 9 8). The seven-bagger holds all seven.
@(test)
test_top_count_six_seven :: proc(t: ^testing.T) {
	h := eval_sampler()
	testing.expect_value(t, top_count(h, .Spades, 7), 7) // A K Q J T 9 8 all present
	testing.expect_value(t, top_count(h, .Spades, 6), 6)
	testing.expect_value(t, top_count(h, .Hearts, 7), 2) // only A K
}

// dhcp writes down honours in short suits: the singleton queen scores 0, not 2, so dhcp < hcp.
@(test)
test_dhcp :: proc(t: ^testing.T) {
	h := eval_sampler()
	testing.expect_value(t, hcp(h), 19) // spades AKQJ=10, hearts AK=7, diamond Q=2
	testing.expect_value(t, dhcp(h), 17) // singleton diamond Q drops from 2 to 0
}

// defense, in half-units, per suit.
@(test)
test_defense :: proc(t: ^testing.T) {
	h := eval_sampler()
	testing.expect_value(t, defense(h, .Spades), 3) // A(+2), K in 7-bagger(+1)
	testing.expect_value(t, defense(h, .Hearts), 4) // A(+2), K len<7(+2)
	testing.expect_value(t, defense(h, .Diamonds), 1) // bare Q, unbacked(+1)
	testing.expect_value(t, defense(h, .Clubs), 0) // no honours
}

// op = sum of offense - defense over the suits.
@(test)
test_op :: proc(t: ^testing.T) {
	h := eval_sampler()
	// offense: spades 7, hearts 2, diamonds 0, clubs 0; defense: 3, 4, 1, 0.
	testing.expect_value(t, op(h), (7 - 3) + (2 - 4) + (0 - 1) + (0 - 0)) // = 1
}

// new_ltc counts only missing A/K/Q, in half-units, with no queen-backing refinement.
@(test)
test_new_ltc :: proc(t: ^testing.T) {
	h := eval_sampler()
	// spades AKQ present -> 0; hearts AK -> 0; diamond singleton, no A -> 3; clubs no AKQ -> 3+2+1=6.
	testing.expect_value(t, new_ltc(h), 9)
	// The refined `losers` differs (queen-backing, no king slot in singleton): 0+0+2+6 = 8.
	testing.expect_value(t, losers(h), 8)
}
