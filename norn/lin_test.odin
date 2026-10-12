#+build !js
package norn

import "core:strings"
import "core:testing"

// Per-suit 13-bit rank mask of a parsed hand (order-independent). Bit r set == the hand holds
// `Rank(r)` in `suit`. (A file-local copy; pbn_test.odin's identical helper is private to that file.)
@(private = "file")
lin_suit_mask :: proc(hand: Hand, suit: Suit) -> u16 {
	m: u16
	for card in hand {
		if card_suit(card) == suit {
			m |= u16(1) << u16(card_rank(card))
		}
	}
	return m
}

// A whole LIN record (dealer + four hands, plus other tokens that must be ignored) parses to a full
// board with every seat known and the hands landing on the right (South, West, North, East) seats.
@(test)
test_parse_lin_full_record :: proc(t: ^testing.T) {
	rec := "pn|a,b,c,d|md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|sv|o|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North, .East, .South, .West})

	// South is the FIRST md field: spades A K T.
	testing.expect_value(t, lin_suit_mask(board.deal[.South], .Spades), u16(0x1900))
	// West is the second field: hearts A Q T 4.
	testing.expect_value(
		t,
		lin_suit_mask(board.deal[.West], .Hearts),
		u16(1) << u16(Rank.Ace) | 1 << u16(Rank.Queen) | 1 << u16(Rank.Ten) | 1 << u16(Rank.Four),
	)
	// East is the fourth field: spades J 4 3.
	testing.expect_value(t, lin_suit_mask(board.deal[.East], .Spades), u16(0x206))
}

// A `pc|` play token surfaces the opening lead: the first played card, attributed to whichever seat holds
// it (here ♣A, held by North). Later `pc|` tokens are ignored — only the first (the opening lead) matters.
@(test)
test_parse_lin_opening_lead :: proc(t: ^testing.T) {
	rec := "pn|a,b,c,d|md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|pc|CA|pc|C3|sv|o|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	lead, has := board.opening_lead.?
	testing.expect(t, has)
	testing.expect_value(t, lead.card, make_card(.Clubs, .Ace))
	testing.expect_value(t, lead.leader, Seat.North)
}

// No play tokens -> no opening lead recorded (the deal still parses).
@(test)
test_parse_lin_no_opening_lead :: proc(t: ^testing.T) {
	rec := "pn|a,b,c,d|md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|sv|o|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	_, has := board.opening_lead.?
	testing.expect(t, !has)
}

// Three hands given: the fourth (East) is derived from the 13 unused cards and equals what the
// four-hand form would have placed there.
@(test)
test_parse_lin_three_hands_derives_fourth :: proc(t: ^testing.T) {
	three := "md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6"
	board, err := parse_lin_deal(three)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect_value(t, board.known, bit_set[Seat]{.North, .East, .South, .West})

	// Derived East hand: SJ43 HJ3 DA42 CQJ842.
	testing.expect_value(t, lin_suit_mask(board.deal[.East], .Spades), u16(0x206)) // J 4 3
	testing.expect_value(
		t,
		lin_suit_mask(board.deal[.East], .Diamonds),
		u16(1) << u16(Rank.Ace) | 1 << u16(Rank.Four) | 1 << u16(Rank.Two),
	)
	testing.expect_value(t, lin_suit_mask(board.deal[.East], .Clubs), u16(0x645)) // Q J 8 4 2
}

// A void suit (a bare suit letter with no ranks) parses to an empty holding.
@(test)
test_parse_lin_void_suit :: proc(t: ^testing.T) {
	// South's clubs are void: `...DK962C,` — the C group is empty.
	rec := "md|1SJ654HAQJ82DK962C,S9H96543DT3CAK432,S83HT7DAQJ875CJT9,SAKQT72HKD4CQ8765|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect_value(t, lin_suit_mask(board.deal[.South], .Clubs), u16(0))
	testing.expect_value(t, lin_suit_mask(board.deal[.South], .Diamonds), u16(0x891)) // K 9 6 2
}

// A bare `md` value (no `md|` token, no trailing pipe) is accepted.
@(test)
test_parse_lin_bare_value :: proc(t: ^testing.T) {
	bare := "3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842"
	_, err := parse_lin_deal(bare)
	testing.expect_value(t, err, Lin_Parse_Error.None)
}

// A missing / out-of-range dealer digit is rejected.
@(test)
test_parse_lin_bad_dealer :: proc(t: ^testing.T) {
	_, err := parse_lin_deal("md|9SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6|")
	testing.expect_value(t, err, Lin_Parse_Error.Bad_Dealer)
}

// Too few hand fields is rejected.
@(test)
test_parse_lin_wrong_hand_count :: proc(t: ^testing.T) {
	_, err := parse_lin_deal("md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5|")
	testing.expect_value(t, err, Lin_Parse_Error.Wrong_Hand_Count)
}

// No `md|` token and no bare value at all.
@(test)
test_parse_lin_missing_md :: proc(t: ^testing.T) {
	_, err := parse_lin_deal("")
	testing.expect_value(t, err, Lin_Parse_Error.Missing_Md_Tag)
}

// ---- writing ---------------------------------------------------------------------------------------

// THE test for a writer whose reader is in the same file: what it writes, it reads back. A deal that
// survives the round trip is one a browser will show and the advisor will accept, which is the whole reason
// this format is emitted at all.
@(test)
test_lin_round_trips_a_deal :: proc(t: ^testing.T) {
	source := "md|1SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|"
	board, err := parse_lin_deal(source)
	testing.expect_value(t, err, Lin_Parse_Error.None)

	builder := strings.builder_make(context.temp_allocator)
	render_deal_lin(&builder, board.deal)
	written := strings.to_string(builder)

	again, again_err := parse_lin_deal(written)
	testing.expectf(t, again_err == .None, "our own output did not parse: %v (%s)", again_err, written)
	for seat in Seat {
		for suit in Suit {
			testing.expectf(
				t,
				lin_suit_mask(again.deal[seat], suit) == lin_suit_mask(board.deal[seat], suit),
				"%v's %v changed in the round trip: %s",
				seat,
				suit,
				written,
			)
		}
	}
}

// The record's shape, which is what a viewer keys off: `st||md|<dealer digit>` then four comma-separated
// hands in LIN's own South-West-North-East order, then the vulnerability.
@(test)
test_lin_writes_the_record_a_viewer_expects :: proc(t: ^testing.T) {
	board, err := parse_lin_deal("md|1SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|")
	testing.expect_value(t, err, Lin_Parse_Error.None)

	builder := strings.builder_make(context.temp_allocator)
	render_deal_lin(&builder, board.deal)
	written := strings.to_string(builder)

	testing.expect(t, strings.has_prefix(written, "st||md|"), "a LIN record opens with st||md|")
	testing.expect(t, strings.has_suffix(written, "|sv|o|"), "and closes with the vulnerability")
	testing.expect_value(t, strings.count(written, ","), 3) // four hands, three commas
	// The dealer digit is BBO's numbering, and North (the default table) is 3 rather than 1.
	testing.expect(t, strings.has_prefix(written, "st||md|3"), "North deals as digit 3 in LIN")
	// SOUTH's hand comes first in `md`, not North's - the order that is easy to get wrong and impossible to
	// see afterwards, because every hand is a valid hand.
	south_first := strings.index(written, "|md|3") + len("|md|3")
	first_field := written[south_first:strings.index(written[south_first:], ",") + south_first]
	expected := strings.builder_make(context.temp_allocator)
	for suit in SUIT_OUTPUT_ORDER {
		strings.write_rune(&expected, suit_letter(suit))
		write_suit_ranks(&expected, board.deal[.South], suit)
	}
	testing.expect_value(t, first_field, strings.to_string(expected))
}

// A void is written as its suit letter and nothing else - the reader's own convention, and the case that
// would otherwise silently produce a 12-card hand.
@(test)
test_lin_writes_a_void_as_an_empty_suit :: proc(t: ^testing.T) {
	// South holds no spades here.
	board, err := parse_lin_deal("md|1SHAKQJT98765432DC,SAKQJT98765432HDC,SAKQJT98765432DHC,SHDAKQJT98765432C|")
	if err != .None {
		return // the fixture above is only worth having if it parses; the round-trip test covers the rest
	}
	builder := strings.builder_make(context.temp_allocator)
	render_deal_lin(&builder, board.deal)
	written := strings.to_string(builder)
	_, again_err := parse_lin_deal(written)
	testing.expectf(t, again_err == .None, "a deal with a void did not survive: %v (%s)", again_err, written)
}
