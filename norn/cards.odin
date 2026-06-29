package norn

/*
	cards.odin — the card model.

	A standard bridge deck has 52 cards: 13 ranks in each of 4 suits. This file defines the
	types for a single card and the helpers to build a full deck and render cards as text.

	ENCODING
	--------
	A `Card` is a single integer in the range 0..=51, computed as:

		card = int(suit) * 13 + int(rank)

	This packs both pieces of information into one small value, which is cheap to copy, store
	in arrays, and shuffle. The two halves are recovered with integer division and modulo:

		suit = card / 13          rank = card % 13

	We deliberately keep the bitfield-per-suit layout that the DDS double-dummy solver prefers
	OUT of this core model. If/when double-dummy analysis is added, conversion happens at that
	boundary only — the generator itself never needs it.

	ORDERING
	--------
	Both enums are declared in ASCENDING bridge strength and given the implicit backing values
	0, 1, 2, ... so the arithmetic above works directly:

		Suit:  Clubs(0) < Diamonds(1) < Hearts(2) < Spades(3)
		Rank:  Two(0) < Three(1) < ... < Ten(8) < Jack(9) < Queen(10) < King(11) < Ace(12)

	Note that *display* order is not the same as strength order: the line export writes suits
	spades-first (S H D C) and ranks high-to-low. That presentation concern lives in render.odin,
	not here.
*/

// Suit, in ascending bridge rank. Backing values are the implicit 0..=3.
Suit :: enum u8 {
	Clubs,
	Diamonds,
	Hearts,
	Spades,
}

// Rank, in ascending strength. Backing values are the implicit 0..=12.
Rank :: enum u8 {
	Two,
	Three,
	Four,
	Five,
	Six,
	Seven,
	Eight,
	Nine,
	Ten,
	Jack,
	Queen,
	King,
	Ace,
}

// The number of distinct suits, ranks, and cards in a standard deck.
SUIT_COUNT :: 4
RANK_COUNT :: 13
DECK_SIZE :: SUIT_COUNT * RANK_COUNT // 52

// A single playing card, encoded as suit*13 + rank (see file header). The value is always in
// the range 0..<DECK_SIZE. `distinct` makes it a separate type from a plain u8 so a raw integer
// cannot be passed where a Card is expected by accident.
Card :: distinct u8

// Build a card from its suit and rank. This is the only place the suit*13+rank encoding is
// applied, so the layout is defined in exactly one spot.
make_card :: proc "contextless" (suit: Suit, rank: Rank) -> Card {
	return Card(u8(suit) * RANK_COUNT + u8(rank))
}

// Recover the suit of a card (the high part of the encoding).
card_suit :: proc "contextless" (card: Card) -> Suit {
	return Suit(u8(card) / RANK_COUNT)
}

// Recover the rank of a card (the low part of the encoding).
card_rank :: proc "contextless" (card: Card) -> Rank {
	return Rank(u8(card) % RANK_COUNT)
}

// Return an ordered, complete 52-card deck. Cards come out grouped by suit (clubs first) and,
// within each suit, in ascending rank (Two first). Because of the suit*13+rank encoding this is
// simply the integers 0..51, so we fill the array directly — `deck[i] == Card(i) ==
// make_card(Suit(i/13), Rank(i%13))`. Callers that want randomness shuffle this; callers that want
// a canonical reference use it as-is.
full_deck :: proc "contextless" () -> [DECK_SIZE]Card {
	deck: [DECK_SIZE]Card
	for i in 0 ..< DECK_SIZE {
		deck[i] = Card(i)
	}
	return deck
}

// The single-character label for a rank, as used on convention cards and in the line export:
// A K Q J T for the honours, and the digit for 2..9. Returns a `rune` — Odin's character type —
// because this is a presentation concern, not a raw byte.
rank_char :: proc "contextless" (rank: Rank) -> rune {
	switch rank {
	case .Ace:
		return 'A'
	case .King:
		return 'K'
	case .Queen:
		return 'Q'
	case .Jack:
		return 'J'
	case .Ten:
		return 'T'
	case .Two, .Three, .Four, .Five, .Six, .Seven, .Eight, .Nine:
		// Two has backing value 0 and prints '2'; Nine has backing value 7 and prints '9'.
		return rune(int('0') + int(rank) + 2)
	}
	return '?' // unreachable: the switch above is exhaustive over Rank
}

// Parse a rank from its single-character label (the inverse of `rank_char`): A K Q J T for the
// honours, the digit 2..9 for the spot cards. Case-insensitive. ok = false on any other byte.
rank_from_char :: proc "contextless" (c: u8) -> (rank: Rank, ok: bool) {
	switch c {
	case 'A', 'a':
		return .Ace, true
	case 'K', 'k':
		return .King, true
	case 'Q', 'q':
		return .Queen, true
	case 'J', 'j':
		return .Jack, true
	case 'T', 't':
		return .Ten, true
	case '2' ..= '9':
		// '2' -> Two (backing 0); '9' -> Nine (backing 7). Mirrors rank_char's digit branch.
		return Rank(int(c) - int('0') - 2), true
	}
	return .Two, false
}

// Parse a suit from its single-character label (the inverse of `suit_letter`): S H D C.
// Case-insensitive. ok = false on any other byte.
suit_from_letter :: proc "contextless" (c: u8) -> (suit: Suit, ok: bool) {
	switch c {
	case 'S', 's':
		return .Spades, true
	case 'H', 'h':
		return .Hearts, true
	case 'D', 'd':
		return .Diamonds, true
	case 'C', 'c':
		return .Clubs, true
	}
	return .Clubs, false
}

// Parse a two-character card label, rank first then suit letter: "AS" (ace of spades), "TH" (ten of
// hearts), "2C" (two of clubs). Case-insensitive. ok = false if the length is wrong or either half
// doesn't parse. The inverse of the `rank_char`/`suit_letter` pair used by the exporters.
parse_card :: proc "contextless" (text: string) -> (card: Card, ok: bool) {
	if len(text) != 2 {
		return 0, false
	}
	rank, rank_ok := rank_from_char(text[0])
	suit, suit_ok := suit_from_letter(text[1])
	if !rank_ok || !suit_ok {
		return 0, false
	}
	return make_card(suit, rank), true
}

// The single-character label for a suit: S H D C. Used by the pretty export and anywhere a
// suit needs naming. (The line export is positional and does not print suit letters.)
suit_letter :: proc "contextless" (suit: Suit) -> rune {
	switch suit {
	case .Spades:
		return 'S'
	case .Hearts:
		return 'H'
	case .Diamonds:
		return 'D'
	case .Clubs:
		return 'C'
	}
	return '?' // unreachable: the switch above is exhaustive over Suit
}
