package norn

/*
	deal_test.odin — unit tests for dealing a board.

	Each test installs its own seeded xoshiro256** generator into the context so dealing is
	independent and reproducible.
*/

import "core:math/rand"
import "core:testing"

// A dealt board must use all 52 cards: every card appears exactly once across the four hands,
// and each hand holds exactly 13.
@(test)
test_deal_board_is_complete_partition :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 42)

	board := deal_board()

	seen: [DECK_SIZE]bool
	total := 0
	for seat_index in 0 ..< SEAT_COUNT {
		hand := board[Seat(seat_index)]
		testing.expect_value(t, len(hand), HAND_SIZE)
		for card in hand {
			idx := int(card)
			testing.expect(t, idx >= 0 && idx < DECK_SIZE, "card out of range in hand")
			testing.expect(t, !seen[idx], "card dealt to more than one hand")
			seen[idx] = true
			total += 1
		}
	}
	testing.expect_value(t, total, DECK_SIZE)
	for was_seen, idx in seen {
		testing.expectf(t, was_seen, "card %d was never dealt", idx)
	}
}

// The same seed must produce the same board, card for card and seat for seat.
@(test)
test_deal_board_is_deterministic :: proc(t: ^testing.T) {
	state_a: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_a, 2026)
	board_a := deal_board()

	state_b: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_b, 2026)
	board_b := deal_board()

	for seat_index in 0 ..< SEAT_COUNT {
		seat := Seat(seat_index)
		for card_index in 0 ..< HAND_SIZE {
			testing.expect_value(t, board_a[seat][card_index], board_b[seat][card_index])
		}
	}
}

// Drawing two boards from one generator should advance the stream, giving different boards.
@(test)
test_consecutive_boards_differ :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 1)

	first := deal_board()
	second := deal_board()

	identical := true
	for seat_index in 0 ..< SEAT_COUNT {
		seat := Seat(seat_index)
		for card_index in 0 ..< HAND_SIZE {
			if first[seat][card_index] != second[seat][card_index] {
				identical = false
				break
			}
		}
	}
	testing.expect(t, !identical, "two consecutive boards were identical")
}
