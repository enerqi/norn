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
test_is_nt5cm_shape :: proc(t: ^testing.T) {
	testing.expect(t, is_nt5cm_shape(balanced_4333()), "4-3-3-3 is a 5CM_nt shape")
	testing.expect(t, is_nt5cm_shape(balanced_5332()), "5-3-3-2 is a 5CM_nt shape")
	testing.expect(t, !is_nt5cm_shape(two_suiter_5422()), "5-4-2-2 is not (it is a 5-4)")
	testing.expect(t, !is_nt5cm_shape(unbalanced_7222()), "7-2-2-2 is not (6+ suit)")
}

@(test)
test_losers :: proc(t: ^testing.T) {
	// spades AKQJ = 0, three low tripletons = 3 each.
	testing.expect_value(t, losers(balanced_4333()), 9)
	// spades AKQJT = 0, hearts AKQJ = 0, two low doubletons = 2 each.
	testing.expect_value(t, losers(two_suiter_5422()), 4)
	// spades AKQ.. = 0, three low doubletons = 2 each.
	testing.expect_value(t, losers(unbalanced_7222()), 6)
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
