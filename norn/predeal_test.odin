package norn

import "core:math/rand"
import "core:testing"

// parse_card round-trips the exporter labels and rejects malformed input.
@(test)
test_parse_card :: proc(t: ^testing.T) {
	as, as_ok := parse_card("AS")
	testing.expect(t, as_ok, "AS should parse")
	testing.expect_value(t, as, make_card(.Spades, .Ace))

	th, th_ok := parse_card("th") // case-insensitive
	testing.expect(t, th_ok, "th should parse")
	testing.expect_value(t, th, make_card(.Hearts, .Ten))

	tc, tc_ok := parse_card("2C")
	testing.expect(t, tc_ok, "2C should parse")
	testing.expect_value(t, tc, make_card(.Clubs, .Two))

	_, bad_len := parse_card("AKS")
	testing.expect(t, !bad_len, "3-char token should fail")
	_, bad_rank := parse_card("1S")
	testing.expect(t, !bad_rank, "rank '1' should fail")
	_, bad_suit := parse_card("AX")
	testing.expect(t, !bad_suit, "suit 'X' should fail")
}

// predeal_validate catches a card fixed to two seats; a clean spec passes.
@(test)
test_predeal_validate :: proc(t: ^testing.T) {
	pd: Predeal
	predeal_add(&pd, .North, make_card(.Spades, .Ace))
	predeal_add(&pd, .South, make_card(.Hearts, .Queen))
	ok, _ := predeal_validate(pd)
	testing.expect(t, ok, "distinct cards should validate")
	testing.expect_value(t, predeal_total(pd), 2)

	dup: Predeal
	predeal_add(&dup, .North, make_card(.Spades, .Ace))
	predeal_add(&dup, .South, make_card(.Spades, .Ace))
	dup_ok, _ := predeal_validate(dup)
	testing.expect(t, !dup_ok, "a card on two seats should fail")
}

// predeal_add refuses a 14th card on a seat.
@(test)
test_predeal_add_overfull :: proc(t: ^testing.T) {
	pd: Predeal
	for r in 0 ..< HAND_SIZE {
		ok := predeal_add(&pd, .North, make_card(.Spades, Rank(r)))
		testing.expect(t, ok, "first 13 cards should be accepted")
	}
	overflow := predeal_add(&pd, .North, make_card(.Hearts, .Two))
	testing.expect(t, !overflow, "the 14th card should be refused")
	testing.expect_value(t, pd.counts[.North], HAND_SIZE)
}

// deal_board_predealt places the fixed cards exactly, deals the rest, and never duplicates a card.
@(test)
test_deal_board_predealt :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2026)

	pd: Predeal
	ns := make_card(.Spades, .Ace)
	nk := make_card(.Spades, .King)
	sq := make_card(.Hearts, .Queen)
	predeal_add(&pd, .North, ns)
	predeal_add(&pd, .North, nk)
	predeal_add(&pd, .South, sq)

	for _ in 0 ..< 200 {
		board := deal_board_predealt(pd)

		// Fixed cards sit in their seats' leading slots.
		testing.expect_value(t, board[.North][0], ns)
		testing.expect_value(t, board[.North][1], nk)
		testing.expect_value(t, board[.South][0], sq)

		// Every card appears exactly once across the whole deal.
		seen: [DECK_SIZE]int
		for seat in Seat {
			for c in board[seat] {
				seen[int(c)] += 1
			}
		}
		for count in seen {
			testing.expect_value(t, count, 1)
		}
	}
}
