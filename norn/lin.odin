package norn

import "core:strings"

/*
	lin.odin — reading a board back from a BBO/IntoBridge LIN deal string.

	LIN is the play-record format used by Bridge Base Online, IntoBridge, RealBridge and friends. A
	full LIN record is a run of `key|value|` tokens carrying player names (`pn|`), the deal (`md|`),
	vulnerability (`sv|`), the auction (`mb|`) and the played cards (`pc|`). This reader turns the `md|`
	deal into the same `Board` that `parse_pbn_deal` yields, so a hand pasted from one of those sites can
	be fed into norn/odin-sims exactly like a PBN `[Deal]` tag, and reads the auction (-> `contract`) and
	the play (-> `play`, see play.odin) when the record carries them. Names and `sv|` are not read here;
	a multi-board vugraph file is split by `split_lin_boards` first.

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

// Parse a LIN `md|` deal into a `Board`. `text` may be a whole LIN record (any run of
// `key|value|` tokens — the `md|` token is located and everything else ignored) or the bare `md`
// value on its own (`1S...,...,...` with or without a trailing `|`). On failure the board is zero and
// `err` says why. All four seats are `known` on success (LIN always records a whole board).
parse_lin_deal :: proc(text: string) -> (board: Board, err: Lin_Parse_Error) {
	value := lin_md_value(text)
	if value == "" {
		return {}, .Missing_Md_Tag
	}

	// The leading dealer digit (1..4); a non-digit here means the value isn't a real `md` payload.
	if value[0] < '1' || value[0] > '4' {
		return {}, .Bad_Dealer
	}
	if seat, ok := lin_dealer_seat(value[0]); ok {
		board.conditions.dealer = seat
	}
	board.conditions.vulnerability = lin_vulnerability(text)
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
	// bare `md` deal, or an all-pass auction — leaves `contract` nil.
	if dealer, dok := lin_dealer_seat(value[0]); dok {
		calls := lin_auction_calls(text, context.temp_allocator)
		if contract, cok := derive_contract(dealer, calls[:]); cok {
			board.contract = contract
			board.play = lin_play(text, board.deal, contract)
		}
	}
	return board, .None
}

// The `sv|` token: `o`/`0`/`-` nobody (or none at all), `n` north-south, `e` east-west, `b` both.
@(private = "file")
lin_vulnerability :: proc(text: string) -> Vulnerability {
	at := -1
	if strings.has_prefix(text, "sv|") {
		at = 0
	} else if i := strings.index(text, "|sv|"); i >= 0 {
		at = i + 1
	}
	if at < 0 || at + 3 >= len(text) {
		return .None
	}
	switch text[at + 3] {
	case 'n', 'N':
		return .North_South
	case 'e', 'E':
		return .East_West
	case 'b', 'B':
		return .Both
	}
	return .None
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

// ---------------------------------------------------------------------------------------------------
// Writing LIN
//
// The reader above exists because hands arrive as LIN: a bridgebase, IntoBridge or RealBridge link carries
// its board as `pn|…|md|…|mb|…|pc|…`, and the advisor reads those. This is the other direction, and it is
// what makes a generated deal SHAREABLE: a `md|` record pastes straight into
//
//	https://play.intobridge.com/hand?lin=…
//	https://www.bridgebase.com/tools/handviewer.html?lin=…
//
// and it reads back through `parse_lin_deal`, so a deal can go out to a browser and come home to the
// advisor without a lossy stop in between. PBN is the FILE interchange format and stays that; LIN is the
// link format, and the two are not substitutes.
//
// What a generated deal can honestly carry is the deal, the dealer and the vulnerability - there is no
// auction and no play here, so no `mb|`/`pc|` tokens are written. A viewer opens such a record on an empty
// auction, which is exactly what these deals are for.

// LIN's vulnerability codes, which are NOT the handviewer query string's (`-` there, `o` here).
@(private = "file")
LIN_VULNERABILITY_CODES := [Vulnerability]string {
	.None        = "o",
	.North_South = "n",
	.East_West   = "e",
	.Both        = "b",
}

// BBO's dealer digit for a seat: the inverse of `lin_dealer_seat`, and the same odd numbering
// (1=South, 2=West, 3=North, 4=East) rather than the seat enum's.
@(private = "file")
lin_dealer_digit :: proc "contextless" (seat: Seat) -> u8 {
	switch seat {
	case .South:
		return '1'
	case .West:
		return '2'
	case .North:
		return '3'
	case .East:
		return '4'
	}
	return '1'
}

/*
Write one deal as a LIN record: `st||md|<dealer><S>,<W>,<N>,<E>|sv|<vul>|`, no trailing newline.

The hands are in LIN's own `md` order - South, West, North, East (`LIN_MD_SEATS`), which is neither the seat
enum's order nor the handviewer's - and each is `S<ranks>H<ranks>D<ranks>C<ranks>`, ranks high to low, a void
written as nothing after its letter. All four hands are written rather than three and a remainder: the
reader accepts either, and a record a person might edit should not depend on arithmetic.

`st||` opens the record because that is what BBO writes and what its viewers expect to find; `sv|` closes it
with the vulnerability. With `randomize_table` the dealer and vulnerability are drawn the same way every
other format draws them, so a batch is not 48 boards all dealt by North with nobody vulnerable.
*/
render_deal_lin :: proc(builder: ^strings.Builder, deal: Deal, randomize_table := false) {
	table := draw_table(.Lin, randomize_table)
	write_lin(builder, deal, table.vulnerability, table.dealer.? or_else .North)
}

// `render_deal_lin` at a given table.
@(private)
write_lin :: proc(builder: ^strings.Builder, deal: Deal, vulnerability: Vulnerability, dealer: Seat) {

	strings.write_string(builder, "st||md|")
	strings.write_byte(builder, lin_dealer_digit(dealer))
	md_seats := LIN_MD_SEATS
	for seat, index in md_seats {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		for suit in SUIT_OUTPUT_ORDER {
			strings.write_rune(builder, suit_letter(suit))
			write_suit_ranks(builder, deal[seat], suit)
		}
	}
	strings.write_string(builder, "|sv|")
	strings.write_string(builder, LIN_VULNERABILITY_CODES[vulnerability])
	strings.write_string(builder, "|")
}
