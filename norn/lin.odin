package norn

import "core:strings"

/*
	lin.odin — reading a board back from a BBO/IntoBridge LIN deal string.

	LIN is the play-record format used by Bridge Base Online, IntoBridge, RealBridge and friends. A
	full LIN record is a run of `key|value|` tokens carrying player names (`pn|`), the deal (`md|`),
	vulnerability (`sv|`), the auction (`mb|`) and the played cards (`pc|`). This reader consumes only
	the `md|` token — the deal — and turns it into the same `Parsed_Board` that `parse_pbn_deal`
	yields, so a hand pasted from one of those sites can be fed into norn/odin-sims exactly like a PBN
	`[Deal]` tag. The auction and play are ignored.

	The `md|` value looks like:

		md|1SAKT.H96.DKT65.C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|

	First comes a single DEALER digit — BBO's 1=South, 2=West, 3=North, 4=East — then up to four
	comma-separated hand fields. Unlike PBN, a hand is written with an explicit SUIT LETTER before
	each group (`S...H...D...C...`, a void suit being the letter with no following ranks), and the four
	hands are always listed in the fixed order SOUTH, WEST, NORTH, EAST regardless of who dealt. The
	last (East) hand is commonly omitted — three hands given, the fourth derived from the remaining 13
	cards — so this reader accepts either three or four hand fields. Every GIVEN hand must be a
	complete 13 cards; the derived hand must also come out to exactly 13, or the string is rejected.

	Only fully- or three-of-four-specified deals are supported (a whole board, as these sites always
	record); there is no partial "declarer + dummy" LIN form, so unlike the PBN reader every seat in
	the result is always `known`.
*/

// The four `md|` hand fields are listed in this seat order (BBO's fixed South, West, North, East),
// independent of the dealer digit. Index i of the comma-split maps to LIN_MD_SEATS[i].
@(private = "file")
LIN_MD_SEATS :: [4]Seat{.South, .West, .North, .East}

// Why a LIN `md|` deal failed to parse. `None` accompanies a successful parse.
Lin_Parse_Error :: enum {
	None,
	Missing_Md_Tag, // no `md|` token found, and the input was not a bare `md` value either
	Bad_Dealer, // the leading dealer character was missing or not one of 1..4
	Wrong_Hand_Count, // not three or four comma-separated hand fields
	Missing_Suit_Letter, // a rank appeared before any `S`/`H`/`D`/`C` suit letter
	Bad_Card, // a rank character did not parse (not A K Q J T or 2..9)
	Wrong_Card_Count, // a given hand, or the derived fourth hand, was not exactly 13 cards
	Duplicate_Card, // the same card appears twice
}

// Parse a LIN `md|` deal into a `Parsed_Board`. `text` may be a whole LIN record (any run of
// `key|value|` tokens — the `md|` token is located and everything else ignored) or the bare `md`
// value on its own (`1S...,...,...` with or without a trailing `|`). On failure the board is zero and
// `err` says why. All four seats are `known` on success (LIN always records a whole board).
parse_lin_deal :: proc(text: string) -> (board: Parsed_Board, err: Lin_Parse_Error) {
	value := lin_md_value(text)
	if value == "" {
		return {}, .Missing_Md_Tag
	}

	// Strip the leading dealer digit (1..4). We don't retain the dealer — Parsed_Board has no such
	// field — but a non-digit here means the value isn't a real `md` payload.
	if value[0] < '1' || value[0] > '4' {
		return {}, .Bad_Dealer
	}
	hands_str := value[1:]

	// Split the comma-separated hand fields (3 or 4 of them), parsing each into its md-order seat.
	md_seats := LIN_MD_SEATS // a constant cannot be indexed by a variable; copy to a local
	seen: [DECK_SIZE]bool // every card placed so far, for duplicate detection
	field_index := 0
	start := 0
	for i := 0; i <= len(hands_str); i += 1 {
		if i < len(hands_str) && hands_str[i] != ',' {
			continue
		}
		field := hands_str[start:i]
		start = i + 1
		if field_index >= SEAT_COUNT {
			return {}, .Wrong_Hand_Count
		}
		seat := md_seats[field_index]
		field_index += 1

		hand, herr := parse_lin_hand(field, &seen)
		if herr != .None {
			return {}, herr
		}
		board.deal[seat] = hand
		board.known += {seat}
	}

	switch field_index {
	case SEAT_COUNT:
	// all four hands given — nothing to derive
	case SEAT_COUNT - 1:
		// The fourth (East) hand was omitted: it is exactly the cards no other hand holds.
		last_seat := md_seats[SEAT_COUNT - 1]
		hand, herr := lin_remaining_hand(&seen)
		if herr != .None {
			return {}, herr
		}
		board.deal[last_seat] = hand
		board.known += {last_seat}
	case:
		return {}, .Wrong_Hand_Count
	}
	// The opening lead, if the record carried a play sequence: the first `pc|` card. LIN always gives a full
	// deal, so its holder (the leader) is always identifiable — set_opening_lead places it.
	if card, ok := lin_first_pc_card(text); ok {
		set_opening_lead(&board, card)
	}
	// The contract, when the record carried an auction (`mb|` tokens): derive its final bid + rule-correct
	// declarer, keyed off the BBO dealer digit (value[0], already validated 1..4 above). No auction — a
	// bare `md` deal, or an all-pass auction — leaves has_contract false.
	if dealer, dok := lin_dealer_seat(value[0]); dok {
		calls := lin_auction_calls(text, context.temp_allocator)
		if lvl, strain, declarer, cok := derive_contract(dealer, calls[:]); cok {
			board.contract_level = lvl
			board.contract_strain = strain
			board.declarer = declarer
			board.has_contract = true
		}
	}
	return board, .None
}

// Map BBO's dealer digit to a Seat: 1=South, 2=West, 3=North, 4=East (BBO's own numbering, NOT the seat
// enum order). ok=false for any other byte.
@(private = "file")
lin_dealer_seat :: proc "contextless" (d: u8) -> (seat: Seat, ok: bool) {
	switch d {
	case '1':
		return .South, true
	case '2':
		return .West, true
	case '3':
		return .North, true
	case '4':
		return .East, true
	}
	return .North, false
}

// Collect the auction's call tokens in order — the value of each `mb|` token (a bid `1S`, a pass `p`, a
// double `d`, a redouble `r`) left to right. The returned strings alias into `text`; the backing dynamic
// array is the caller's to free (pass `context.temp_allocator` to avoid that). Empty when there is no
// auction in the record.
@(private = "file")
lin_auction_calls :: proc(text: string, allocator := context.allocator) -> [dynamic]string {
	calls := make([dynamic]string, allocator)
	rest := text
	for {
		mi := strings.index(rest, "mb|")
		if mi < 0 {
			break
		}
		rest = rest[mi + len("mb|"):]
		val := rest
		if bar := strings.index_byte(rest, '|'); bar >= 0 {
			val = rest[:bar]
			rest = rest[bar + 1:]
		} else {
			rest = ""
		}
		append(&calls, val)
	}
	return calls
}

// The card in the first `pc|` token (the opening lead) as `<suit-letter><rank>`, e.g. `pc|S4|` -> ♠4. `ok`
// is false when there is no `pc|` token or its value does not parse as a card. LIN ranks are single
// characters (ten is `T`, never `10`), so the value is exactly two bytes.
@(private = "file")
lin_first_pc_card :: proc(text: string) -> (card: Card, ok: bool) {
	pi := strings.index(text, "pc|")
	if pi < 0 {
		return {}, false
	}
	val := text[pi + len("pc|"):]
	if bar := strings.index_byte(val, '|'); bar >= 0 {
		val = val[:bar]
	}
	if len(val) < 2 {
		return {}, false
	}
	suit, sok := suit_from_letter(val[0])
	if !sok {
		return {}, false
	}
	rank, rok := rank_from_char(val[1])
	if !rok {
		return {}, false
	}
	return make_card(suit, rank), true
}

// Extract the `md` value from `text`: the token after `md|`, up to the next `|` (or end of input). If
// there is no `md|` token the whole trimmed input is treated as a bare `md` value, with any trailing
// `|` stripped. Returns "" when the result is empty.
@(private = "file")
lin_md_value :: proc(text: string) -> string {
	value := strings.trim_space(text)
	if mi := strings.index(value, "md|"); mi >= 0 {
		value = value[mi + len("md|"):]
	}
	if bar := strings.index_byte(value, '|'); bar >= 0 {
		value = value[:bar]
	}
	return value
}

// Parse one LIN hand field (`S...H...D...C...`, suit letters introducing each group, a void being a
// bare letter) into a full 13-card `Hand`, recording each card in `seen` and rejecting duplicates.
// Suit letters and rank characters never collide (S H D C are none of A K Q J T 2..9), so a byte is
// unambiguously one or the other.
@(private = "file")
parse_lin_hand :: proc(field: string, seen: ^[DECK_SIZE]bool) -> (hand: Hand, err: Lin_Parse_Error) {
	current_suit: Suit
	have_suit := false
	count := 0
	for j := 0; j < len(field); j += 1 {
		c := field[j]
		if suit, is_suit := suit_from_letter(c); is_suit {
			current_suit = suit
			have_suit = true
			continue
		}
		if !have_suit {
			return {}, .Missing_Suit_Letter
		}
		rank, rank_ok := rank_from_char(c)
		if !rank_ok {
			return {}, .Bad_Card
		}
		card := make_card(current_suit, rank)
		if seen[int(card)] {
			return {}, .Duplicate_Card
		}
		seen[int(card)] = true
		if count >= HAND_SIZE {
			return {}, .Wrong_Card_Count
		}
		hand[count] = card
		count += 1
	}
	if count != HAND_SIZE {
		return {}, .Wrong_Card_Count
	}
	return hand, .None
}

// Build the hand of every card not yet in `seen` (the omitted fourth hand). It must total exactly 13.
@(private = "file")
lin_remaining_hand :: proc(seen: ^[DECK_SIZE]bool) -> (hand: Hand, err: Lin_Parse_Error) {
	count := 0
	for card in full_deck() {
		if seen[int(card)] {
			continue
		}
		if count >= HAND_SIZE {
			return {}, .Wrong_Card_Count
		}
		hand[count] = card
		count += 1
	}
	if count != HAND_SIZE {
		return {}, .Wrong_Card_Count
	}
	return hand, .None
}
