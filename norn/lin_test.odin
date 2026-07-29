package norn

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
