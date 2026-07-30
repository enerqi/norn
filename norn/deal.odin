package norn

/*
	deal.odin — hands, seats, and dealing a full deal.

	A "deal" (or "deal") is one complete distribution of all 52 cards to the four players. Each
	player ("seat") receives a 13-card "hand".

	The seats are named by compass direction. We declare them in the order North, East, South,
	West — the clockwise order in which cards are dealt at the table, and the order the line
	export writes them (N|E|S|W).
*/

// The four players at a bridge table, in dealing/printing order.
Seat :: enum {
	North,
	East,
	South,
	West,
}

// Parse a seat from its single-character label: N E S W (the compass initials). Case-insensitive.
// ok = false on any other byte. Used by the PBN reader to read the deal tag's prefix seat.
seat_from_letter :: proc "contextless" (c: u8) -> (seat: Seat, ok: bool) {
	switch c {
	case 'N', 'n':
		return .North, true
	case 'E', 'e':
		return .East, true
	case 'S', 's':
		return .South, true
	case 'W', 'w':
		return .West, true
	}
	return .North, false
}

// Number of seats (players) and cards in one hand.
SEAT_COUNT :: 4
HAND_SIZE :: 13

// One player's 13 cards. They are stored in whatever order they were dealt; grouping by suit and
// sorting for display is a presentation concern handled by the exporters, not here.
Hand :: [HAND_SIZE]Card

// A complete deal: one hand per seat. This is an "enumerated array" — it is indexed directly by a
// `Seat` value (e.g. `deal[.North]`), so the seat and its hand can never get out of step.
Deal :: [Seat]Hand

// Deal one random deal, drawing randomness from `context.random_generator`. We take a fresh
// ordered deck, shuffle it into a uniformly random permutation, then hand it out. Because the
// permutation is already uniform, the contiguous split done by `deal_from_deck` is itself a
// uniform deal — no further randomisation is needed.
deal_hands :: proc() -> Deal {
	deck := full_deck()
	shuffle(deck[:])
	return deal_from_deck(deck)
}

// Hand out an already-ordered 52-card deck to the four seats: the first 13 cards to North, the
// next 13 to East, then South, then West. This step contains no randomness, which keeps it pure
// and directly testable, and is where predeal (fixing specific cards to specific seats) will hook
// in later — it would arrange `deck` before this split.
deal_from_deck :: proc(deck: [DECK_SIZE]Card) -> Deal {
	deal: Deal
	for seat_index in 0 ..< SEAT_COUNT {
		seat := Seat(seat_index)
		start := seat_index * HAND_SIZE
		for card_index in 0 ..< HAND_SIZE {
			deal[seat][card_index] = deck[start + card_index]
		}
	}
	return deal
}
