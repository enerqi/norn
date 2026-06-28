package norn

/*
	predeal.odin — fixing specific cards to specific seats before the random deal.

	"Predeal" nails chosen cards to chosen seats; the rest of the deck is shuffled and dealt around
	them. The board stays uniformly random over the FREE cards — it is just a deal conditioned on the
	fixed holdings. Two uses: studying a fixed motif, and speeding up rare conditions (express the
	exact-card part of a condition as a predeal and drop it from the predicate, so reject sampling
	runs far fewer iterations).

	The spec is a plain value (no heap), so it is cheap to copy and safe to share across the worker
	threads that drive frequency measurement. Build it with `predeal_add`, check it with
	`predeal_validate`, then deal with `deal_board_predealt`.
*/

import "core:fmt"

// Cards fixed to each seat before dealing. `counts[seat]` of `cards[seat]` are in use (the rest of
// the array is unspecified). A whole-deal value, indexed by `Seat` like `Deal` itself.
Predeal :: struct {
	cards:  [Seat][HAND_SIZE]Card,
	counts: [Seat]int,
}

// Fix `card` to `seat`. Returns false (without changing anything) if that seat already holds a full
// 13 cards. Does NOT check for duplicates across seats — call `predeal_validate` once the whole spec
// is built for that.
predeal_add :: proc(pd: ^Predeal, seat: Seat, card: Card) -> (ok: bool) {
	if pd.counts[seat] >= HAND_SIZE {
		return false
	}
	pd.cards[seat][pd.counts[seat]] = card
	pd.counts[seat] += 1
	return true
}

// Total number of cards fixed across all seats.
predeal_total :: proc(pd: Predeal) -> (total: int) {
	for seat in Seat {
		total += pd.counts[seat]
	}
	return
}

// Validate a completed spec: no card may be fixed to more than one seat (a seat over-fill is already
// prevented by `predeal_add`). Returns ok = false with a message naming the offending card.
predeal_validate :: proc(pd: Predeal) -> (ok: bool, message: string) {
	seen: [DECK_SIZE]bool
	for seat in Seat {
		for k in 0 ..< pd.counts[seat] {
			c := pd.cards[seat][k]
			if seen[int(c)] {
				return false, fmt.tprintf(
					"card %c%c is predealt to more than one seat",
					rank_char(card_rank(c)),
					suit_letter(card_suit(c)),
				)
			}
			seen[int(c)] = true
		}
	}
	return true, ""
}

// Deal one board with `pd`'s cards fixed to their seats and the remaining cards dealt at random.
// Drawing randomness from `context.random_generator` (as `deal_board` does). The free cards are a
// uniformly shuffled pool handed out to fill each seat up to 13, so the result is a uniform deal
// conditioned on the predeal. Assumes `pd` has passed `predeal_validate`.
deal_board_predealt :: proc(pd: Predeal) -> Deal {
	// Mark fixed cards, then collect the rest into a pool (no heap: fixed-size arrays).
	used: [DECK_SIZE]bool
	for seat in Seat {
		for k in 0 ..< pd.counts[seat] {
			used[int(pd.cards[seat][k])] = true
		}
	}
	pool: [DECK_SIZE]Card
	pool_len := 0
	for i in 0 ..< DECK_SIZE {
		if !used[i] {
			pool[pool_len] = Card(i)
			pool_len += 1
		}
	}
	shuffle(pool[:pool_len])

	board: Deal
	pi := 0
	for seat_index in 0 ..< SEAT_COUNT {
		seat := Seat(seat_index)
		n := pd.counts[seat]
		for k in 0 ..< n {
			board[seat][k] = pd.cards[seat][k]
		}
		for k in n ..< HAND_SIZE {
			board[seat][k] = pool[pi]
			pi += 1
		}
	}
	return board
}
