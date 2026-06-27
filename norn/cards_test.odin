package norn

/*
	cards_test.odin — unit tests for the card model.

	Run the whole suite with `just test`, or a single test with `just test1 NAME`.
*/

import "core:testing"

// A full deck must contain every one of the 52 distinct cards exactly once.
@(test)
test_full_deck_is_complete_and_unique :: proc(t: ^testing.T) {
	deck := full_deck()
	testing.expect_value(t, len(deck), DECK_SIZE)

	seen: [DECK_SIZE]bool
	for card in deck {
		idx := int(card)
		testing.expect(t, idx >= 0 && idx < DECK_SIZE, "card out of range")
		testing.expect(t, !seen[idx], "duplicate card in deck")
		seen[idx] = true
	}
	for was_seen, idx in seen {
		testing.expectf(t, was_seen, "card %d missing from deck", idx)
	}
}

// The deck is laid out canonically: deck[i] == Card(i), clubs-then-up, low-rank-then-up.
@(test)
test_full_deck_ordering :: proc(t: ^testing.T) {
	deck := full_deck()
	testing.expect_value(t, deck[0], make_card(.Clubs, .Two)) // first card
	testing.expect_value(t, deck[DECK_SIZE - 1], make_card(.Spades, .Ace)) // last card
	for card, i in deck {
		testing.expect_value(t, card, Card(i))
	}
}

// make_card and the card_suit/card_rank accessors must round-trip for every suit/rank pair.
@(test)
test_card_encode_decode_roundtrip :: proc(t: ^testing.T) {
	for suit in 0 ..< SUIT_COUNT {
		for rank in 0 ..< RANK_COUNT {
			s := Suit(suit)
			r := Rank(rank)
			card := make_card(s, r)
			testing.expect_value(t, card_suit(card), s)
			testing.expect_value(t, card_rank(card), r)
		}
	}
}

// Rank characters follow the convention-card labels: A K Q J T plus digits 2..9.
@(test)
test_rank_char :: proc(t: ^testing.T) {
	testing.expect_value(t, rank_char(.Ace), 'A')
	testing.expect_value(t, rank_char(.King), 'K')
	testing.expect_value(t, rank_char(.Queen), 'Q')
	testing.expect_value(t, rank_char(.Jack), 'J')
	testing.expect_value(t, rank_char(.Ten), 'T')
	testing.expect_value(t, rank_char(.Nine), '9')
	testing.expect_value(t, rank_char(.Two), '2')
}

// Suit letters are S H D C.
@(test)
test_suit_letter :: proc(t: ^testing.T) {
	testing.expect_value(t, suit_letter(.Spades), 'S')
	testing.expect_value(t, suit_letter(.Hearts), 'H')
	testing.expect_value(t, suit_letter(.Diamonds), 'D')
	testing.expect_value(t, suit_letter(.Clubs), 'C')
}
