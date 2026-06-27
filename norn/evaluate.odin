package norn

/*
	evaluate.odin — hand evaluation primitives.

	These are the building blocks that bridge conditions are written in terms of: how long a suit
	is, how many high-card points a hand holds, its shape, whether it is balanced, and so on. They
	mirror the vocabulary of the `deal` engine's Tcl library (`hcp`, `controls`, suit lengths,
	`pattern`/`shape`, `balanced`, the `TopN` honour vectors) so that the ~85 predicates in our
	`deal-utils.tcl` can be ported almost line-for-line on top of them.

	Everything here is a pure function of a `Hand`. A multi-seat condition simply evaluates several
	hands of a `Deal` and compares the results.

	NOTE on counts: a `Hand` is the 13 cards as dealt, in no particular order, so these helpers scan
	all 13 cards. That is plenty fast for reject sampling; if profiling ever shows it matters, a hand
	could carry a precomputed per-suit summary instead.
*/

// Number of cards the hand holds in `suit` (0..13).
suit_length :: proc(hand: Hand, suit: Suit) -> int {
	length := 0
	for card in hand {
		if card_suit(card) == suit {
			length += 1
		}
	}
	return length
}

// Does the hand hold this exact card?
holds :: proc(hand: Hand, suit: Suit, rank: Rank) -> bool {
	target := make_card(suit, rank)
	for card in hand {
		if card == target {
			return true
		}
	}
	return false
}

// High-card points for the whole hand: Ace=4, King=3, Queen=2, Jack=1.
hcp :: proc(hand: Hand) -> int {
	total := 0
	for card in hand {
		#partial switch card_rank(card) {
		case .Ace:
			total += 4
		case .King:
			total += 3
		case .Queen:
			total += 2
		case .Jack:
			total += 1
		}
	}
	return total
}

// Control count for the whole hand: Ace=2, King=1. (Aces and kings win tricks directly; controls
// matter for slam bidding.)
controls :: proc(hand: Hand) -> int {
	total := 0
	for card in hand {
		#partial switch card_rank(card) {
		case .Ace:
			total += 2
		case .King:
			total += 1
		}
	}
	return total
}

// How many of the top `n` ranks the hand holds in `suit`. `top_count(hand, suit, 2)` counts A and
// K present; `top_count(hand, suit, 4)` counts A K Q J (the "honours"). `n` must be 0..5.
//
// This is the equivalent of `deal`'s `TopN` honour vectors, e.g. `[Top4 $hand spades]`.
top_count :: proc(hand: Hand, suit: Suit, n: int) -> int {
	// The honour ranks from the top down; index 0 is the highest.
	top_ranks := [5]Rank{.Ace, .King, .Queen, .Jack, .Ten}
	count := 0
	for i in 0 ..< n {
		if holds(hand, suit, top_ranks[i]) {
			count += 1
		}
	}
	return count
}

// The hand's shape: suit lengths in S H D C order, e.g. a 5-4-2-2 with 5 spades is {5, 4, 2, 2}.
// Index 0 is spades, matching `deal`'s `[hand shape]` string "s h d c".
shape :: proc(hand: Hand) -> [SUIT_COUNT]int {
	return [SUIT_COUNT]int {
		suit_length(hand, .Spades),
		suit_length(hand, .Hearts),
		suit_length(hand, .Diamonds),
		suit_length(hand, .Clubs),
	}
}

// The hand's pattern: the four suit lengths sorted high-to-low and suit-agnostic, e.g. {5, 4, 2, 2}.
// This is `deal`'s `[hand pattern]` (a flat 5-4-2-2 regardless of which suits are long). Used for
// shape tests that don't care which suit is which.
pattern :: proc(hand: Hand) -> [SUIT_COUNT]int {
	lengths := shape(hand)
	// Selection sort, descending. Only four elements, so simplicity beats cleverness.
	for i in 0 ..< SUIT_COUNT {
		largest := i
		for j in i + 1 ..< SUIT_COUNT {
			if lengths[j] > lengths[largest] {
				largest = j
			}
		}
		lengths[i], lengths[largest] = lengths[largest], lengths[i]
	}
	return lengths
}

// Is the hand balanced? Matches `deal`'s definition: no 5-card major and the sum of squared suit
// lengths is at most 47. That admits exactly the 4-3-3-3, 4-4-3-2, and (minor) 5-3-3-2 shapes and
// rejects anything with a singleton, void, or a long suit.
is_balanced :: proc(hand: Hand) -> bool {
	s := suit_length(hand, .Spades)
	h := suit_length(hand, .Hearts)
	d := suit_length(hand, .Diamonds)
	c := suit_length(hand, .Clubs)
	if s >= 5 || h >= 5 {
		return false
	}
	return s * s + h * h + d * d + c * c <= 47
}

// Is the hand semi-balanced? Matches `deal`'s definition: no suit shorter than a doubleton, no
// major longer than 5, and no minor longer than 6. Admits balanced hands plus 5-4-2-2 and 6-3-2-2
// types.
is_semibalanced :: proc(hand: Hand) -> bool {
	s := suit_length(hand, .Spades)
	h := suit_length(hand, .Hearts)
	d := suit_length(hand, .Diamonds)
	c := suit_length(hand, .Clubs)
	return s >= 2 && h >= 2 && d >= 2 && c >= 2 && s <= 5 && h <= 5 && d <= 6 && c <= 6
}
