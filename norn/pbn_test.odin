package norn

import "core:strings"
import "core:testing"

// The 13 ranks of one suit, high-to-low, as the PBN writer emits them.
ALL_RANKS :: "AKQJT98765432"

// Per-suit 13-bit rank mask of a parsed hand (order-independent, so it survives the writer's
// high-to-low re-sort). Bit r set == the hand holds the card of `Rank(r)` in `suit`.
@(private = "file")
suit_mask :: proc(hand: Hand, suit: Suit) -> u16 {
	m: u16
	for card in hand {
		if card_suit(card) == suit {
			m |= u16(1) << u16(card_rank(card))
		}
	}
	return m
}

// A full deal written to PBN then read back must reproduce every seat's holdings exactly.
@(test)
test_parse_pbn_full_deal_roundtrip :: proc(t: ^testing.T) {
	original := deal_from_deck(full_deck())

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render_deal_pbn(&b, original)

	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North, .East, .South, .West})

	for seat in SEAT_OUTPUT_ORDER {
		for suit in SUIT_OUTPUT_ORDER {
			testing.expect_value(t, suit_mask(board.deal[seat], suit), suit_mask(original[seat], suit))
		}
	}
}

// A `[Play]` block surfaces the opening lead: its first card token, attributed to whichever seat holds it.
// Built off a rendered full deal (guaranteed valid 52 cards) with East's first card appended as the lead.
// Absent a `[Play]` block, no opening lead is recorded.
@(test)
test_parse_pbn_opening_lead :: proc(t: ^testing.T) {
	original := deal_from_deck(full_deck())
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render_deal_pbn(&b, original)

	// The deal alone: no play sequence -> no opening lead.
	deal_only := strings.clone(strings.to_string(b))
	defer delete(deal_only)
	plain, perr := parse_pbn_deal(deal_only)
	testing.expect_value(t, perr, Pbn_Parse_Error.None)
	testing.expect(t, !plain.has_opening_lead)

	// Append a `[Play "E"]` block whose first card is East's first card, written as a PBN token.
	lead := original[.East][0]
	strings.write_string(&b, "\n[Play \"E\"]\n")
	strings.write_rune(&b, suit_letter(card_suit(lead)))
	strings.write_rune(&b, rank_char(card_rank(lead)))
	strings.write_string(&b, " -\n")
	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect(t, board.has_opening_lead)
	testing.expect_value(t, board.opening_lead, lead)
	testing.expect_value(t, board.opening_leader, Seat.East)
}

// The bare deal value (no surrounding `[Deal "..."]` tag) is accepted too.
@(test)
test_parse_pbn_bare_value :: proc(t: ^testing.T) {
	original := deal_from_deck(full_deck())
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render_deal_pbn(&b, original)

	full := strings.to_string(b)
	// Strip the `[Deal "` prefix and `"]` suffix to leave just `N:...`.
	inner := full[len(`[Deal "`):len(full) - len(`"]`)]
	board, err := parse_pbn_deal(inner)
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North, .East, .South, .West})
}

// A 2-hand declarer+dummy tag: two known partners (N all spades, S all hearts), the defenders `-`.
@(test)
test_parse_pbn_two_hand :: proc(t: ^testing.T) {
	// N = 13 spades, S = 13 hearts, E and W unknown.
	tag := `[Deal "N:` + ALL_RANKS + `... - .` + ALL_RANKS + `.. -"]`
	board, err := parse_pbn_deal(tag)
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North, .South})
	testing.expect_value(t, suit_mask(board.deal[.North], .Spades), u16(0x1FFF)) // all 13 ranks
	testing.expect_value(t, suit_mask(board.deal[.North], .Hearts), u16(0))
	testing.expect_value(t, suit_mask(board.deal[.South], .Hearts), u16(0x1FFF))
	testing.expect_value(t, suit_mask(board.deal[.South], .Spades), u16(0))
}

// A void suit (three trailing dots) round-trips: N holds all spades, three void suits.
@(test)
test_parse_pbn_void_suits :: proc(t: ^testing.T) {
	board, err := parse_pbn_deal(`N:` + ALL_RANKS + `... - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North})
	testing.expect_value(t, suit_mask(board.deal[.North], .Spades), u16(0x1FFF))
	testing.expect_value(t, suit_mask(board.deal[.North], .Clubs), u16(0))
}

// The prefix seat names the first hand field; the rest follow clockwise (N E S W). With prefix `E`,
// the fields map to E, S, W, N — so field-0 (spades) is East, field-2 (hearts) is South here.
@(test)
test_parse_pbn_prefix_seat :: proc(t: ^testing.T) {
	tag := `E:` + ALL_RANKS + `... - .` + ALL_RANKS + `.. -`
	board, err := parse_pbn_deal(tag)
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.East, .West})
	testing.expect_value(t, suit_mask(board.deal[.East], .Spades), u16(0x1FFF))
	testing.expect_value(t, suit_mask(board.deal[.West], .Hearts), u16(0x1FFF))
}

@(test)
test_parse_pbn_bad_prefix :: proc(t: ^testing.T) {
	_, err := parse_pbn_deal(`X:` + ALL_RANKS + `... - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.Bad_Prefix_Seat)

	// A two-letter prefix puts the colon at index 2, not 1.
	_, err2 := parse_pbn_deal(`NN:` + ALL_RANKS + `... - - -`)
	testing.expect_value(t, err2, Pbn_Parse_Error.Bad_Prefix_Seat)
}

@(test)
test_parse_pbn_bad_card :: proc(t: ^testing.T) {
	_, err := parse_pbn_deal(`N:X... - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.Bad_Card)
}

@(test)
test_parse_pbn_wrong_card_count :: proc(t: ^testing.T) {
	// N holds only three spades.
	_, err := parse_pbn_deal(`N:AKQ... - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.Wrong_Card_Count)
}

@(test)
test_parse_pbn_duplicate_card :: proc(t: ^testing.T) {
	// The ace of spades appears twice in one hand.
	_, err := parse_pbn_deal(`N:AAKQJT9876543... - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.Duplicate_Card)
}

@(test)
test_parse_pbn_wrong_hand_count :: proc(t: ^testing.T) {
	// Only two hand fields.
	_, err := parse_pbn_deal(`N:` + ALL_RANKS + `... .` + ALL_RANKS + `..`)
	testing.expect_value(t, err, Pbn_Parse_Error.Wrong_Hand_Count)
}

@(test)
test_parse_pbn_bad_suit_count :: proc(t: ^testing.T) {
	// A hand with only two suits (one dot).
	_, err := parse_pbn_deal(`N:AK.QJ - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.Bad_Suit_Count)
}

@(test)
test_parse_pbn_no_hands :: proc(t: ^testing.T) {
	_, err := parse_pbn_deal(`N:- - - -`)
	testing.expect_value(t, err, Pbn_Parse_Error.No_Hands)
}

@(test)
test_parse_pbn_empty :: proc(t: ^testing.T) {
	_, err := parse_pbn_deal("")
	testing.expect_value(t, err, Pbn_Parse_Error.Missing_Deal_Tag)
}
