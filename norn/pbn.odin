package norn

import "core:strings"

/*
	pbn.odin — reading a board back from Portable Bridge Notation.

	The PBN *writer* lives in render.odin (`render_deal_pbn` / `Output_Format.Pbn`); this file is its
	inverse. It exists so an externally-produced deal — e.g. a hand recognised from an image by the
	hand-ocr tool — can be fed into norn/odin-sims as a `[Deal]` tag instead of being dealt randomly.

	The tag looks like:

		[Deal "N:T84.QJ.KQ976.A52 Q9.AK87.J8.KQ964 KJ32.T96.AT.J873 A765.5432.543.T"]

	The prefix seat (here `N`) names the FIRST of the four space-separated hand fields; the remaining
	three follow clockwise (N->E->S->W, i.e. `Seat` order). Each hand is four dot-separated suits in
	S.H.D.C order, ranks in any order (a void is the empty string, surfacing as adjacent dots).

	PARTIAL DEALS. A hand written as a lone `-` is UNKNOWN (not specified). This is how a 2-hand
	"declarer + dummy" board is expressed: the two known hands in full, the two defenders as `-`. The
	result carries a `known: bit_set[Seat]` marking which seats were actually given, so downstream code
	can branch (combo needs only the two NS hands; DDS/par needs all four). Every SPECIFIED hand must be
	a complete 13 cards — this reader does not accept mid-play partial hands (fewer than 13 cards), which
	real declarer+dummy input never is. Unknown seats' entries in `deal` are left unspecified; read them
	only for seats present in `known`.
*/

// A board parsed from a PBN `[Deal]` tag. `deal` holds every SPECIFIED hand as a full 13 cards; seats
// written `-` (unknown) are left unspecified and excluded from `known`. A standard 4-hand tag yields
// `known == {.North, .East, .South, .West}`; a 2-hand declarer+dummy tag yields just those two seats.
Parsed_Board :: struct {
	deal:             Deal,
	known:            bit_set[Seat],
	// The recorded opening lead, when the source carried a play sequence (LIN `pc|`, PBN `[Play]`) AND the
	// led card sits in a KNOWN hand (so its leader is identifiable — always true for a full deal, never for
	// a 2-hand board whose lead belongs to an unspecified defender). `opening_leader` is the seat holding it.
	opening_lead:     Card,
	opening_leader:   Seat,
	has_opening_lead: bool,
	// The contract the record names, when present. LIN: derived from the `mb|` auction (final bid + the
	// rule-correct declarer). PBN: from `[Contract]` + `[Declarer]` tags. All three fields are meaningful
	// only when has_contract is set — false for a bare `[Deal]` tag, a passed-out auction, or a 2-hand OCR
	// board with no metadata. `declarer` is the seat that first named the final denomination for its side.
	contract_level:   int, // 1..7
	contract_strain:  Contract_Strain,
	declarer:         Seat,
	has_contract:     bool,
}

// Record `card` as the board's opening lead: find the KNOWN seat that holds it and mark it the leader. A
// no-op (has_opening_lead stays false) when the card is in no known hand — e.g. a 2-hand board whose lead
// belongs to an unspecified defender. Called by the LIN / PBN readers once the deal is built.
set_opening_lead :: proc(board: ^Parsed_Board, card: Card) {
	for seat in board.known {
		for c in board.deal[seat] {
			if c == card {
				board.opening_lead = card
				board.opening_leader = seat
				board.has_opening_lead = true
				return
			}
		}
	}
}

// Why a PBN `[Deal]` tag failed to parse. `None` accompanies a successful parse.
Pbn_Parse_Error :: enum {
	None,
	Missing_Deal_Tag, // no deal string found (empty input, or a `[Deal "` with no closing quote)
	Bad_Prefix_Seat, // the leading `X:` seat letter is missing or not one of N E S W
	Wrong_Hand_Count, // not exactly four space-separated hand fields
	Bad_Suit_Count, // a hand does not have exactly four dot-separated suits
	Bad_Card, // a rank character did not parse (not A K Q J T or 2..9)
	Wrong_Card_Count, // a specified (non-`-`) hand is not exactly 13 cards
	Duplicate_Card, // the same card appears in two hands, or twice in one hand
	No_Hands, // every hand was `-` (nothing to analyse)
}

// Parse a PBN `[Deal]` tag into a `Parsed_Board`. `text` may be a whole line containing the tag
// (`[Deal "N:..."]`, with any surrounding text ignored) or the bare deal value (`N:...`). On failure
// the returned board is zero and `err` says why. The parse is strict: exactly four hand fields, each
// either `-` (unknown) or a full 13-card `S.H.D.C` hand, all cards across the board distinct.
parse_pbn_deal :: proc(text: string) -> (board: Parsed_Board, err: Pbn_Parse_Error) {
	value := pbn_deal_value(text)
	if value == "" {
		return {}, .Missing_Deal_Tag
	}

	// Split off the prefix seat: everything before the first ':' must be a single seat letter.
	colon := strings.index_byte(value, ':')
	if colon != 1 {
		return {}, .Bad_Prefix_Seat
	}
	prefix, prefix_ok := seat_from_letter(value[0])
	if !prefix_ok {
		return {}, .Bad_Prefix_Seat
	}
	hands_str := value[colon + 1:]

	seen: [DECK_SIZE]bool // every card placed so far, for cross-hand duplicate detection
	field_index := 0
	start := 0
	// Walk the space-separated hand fields. Assign field i to the seat i steps clockwise from the
	// prefix (Seat's backing order N E S W already IS clockwise, so we step mod SEAT_COUNT).
	for i := 0; i <= len(hands_str); i += 1 {
		if i < len(hands_str) && hands_str[i] != ' ' {
			continue
		}
		field := hands_str[start:i]
		start = i + 1
		if field_index >= SEAT_COUNT {
			return {}, .Wrong_Hand_Count
		}
		seat := Seat((u8(prefix) + u8(field_index)) % SEAT_COUNT)
		field_index += 1

		if field == "-" {
			continue // unknown hand: leave it out of `known`
		}
		hand, herr := parse_pbn_hand(field, &seen)
		if herr != .None {
			return {}, herr
		}
		board.deal[seat] = hand
		board.known += {seat}
	}
	if field_index != SEAT_COUNT {
		return {}, .Wrong_Hand_Count
	}
	if board.known == {} {
		return {}, .No_Hands
	}
	if card, ok := pbn_first_play_card(text); ok {
		set_opening_lead(&board, card)
	}
	// The contract, when the record carried both `[Contract]` and `[Declarer]` (a full PBN record, or the
	// hand-ocr replay metadata). Both are required: the declarer fixes the declaring side. Absent or a
	// passed-out `[Contract "Pass"]` leaves has_contract false.
	if lvl, strain, cok := pbn_contract(text); cok {
		if declarer, dok := pbn_declarer(text); dok {
			board.contract_level = lvl
			board.contract_strain = strain
			board.declarer = declarer
			board.has_contract = true
		}
	}
	return board, .None
}

// The contract from a `[Contract "..."]` tag: level 1..7 plus denomination (`4H`, `3NT`, `4SX` — a
// trailing `X`/`XX` doubling marker is ignored, as the downstream contract model carries no doubling).
// ok=false when the tag is absent, is `Pass`/empty, or otherwise malformed.
@(private = "file")
pbn_contract :: proc(text: string) -> (level: int, strain: Contract_Strain, ok: bool) {
	val, found := pbn_tag_value(text, "Contract")
	if !found || len(val) < 2 {
		return 0, .NoTrump, false
	}
	if val[0] < '1' || val[0] > '7' {
		return 0, .NoTrump, false
	}
	denom := val[1:]
	for len(denom) > 0 && (denom[len(denom) - 1] == 'X' || denom[len(denom) - 1] == 'x') {
		denom = denom[:len(denom) - 1]
	}
	s, sok := contract_strain_from_token(denom)
	if !sok {
		return 0, .NoTrump, false
	}
	return int(val[0] - '0'), s, true
}

// The declarer seat from a `[Declarer "N"]` tag (N/E/S/W). ok=false when the tag is absent or its value
// is not a seat letter.
@(private = "file")
pbn_declarer :: proc(text: string) -> (seat: Seat, ok: bool) {
	val, found := pbn_tag_value(text, "Declarer")
	if !found || len(val) < 1 {
		return .North, false
	}
	return seat_from_letter(val[0])
}

// The quoted value of a `[<name> "..."]` tag, if present — a generic reader mirroring pbn_deal_value.
// Returns "" / false when the tag is absent or has no closing quote.
@(private = "file")
pbn_tag_value :: proc(text: string, name: string) -> (value: string, found: bool) {
	opener := strings.concatenate({"[", name, " \""}, context.temp_allocator)
	di := strings.index(text, opener)
	if di < 0 {
		return "", false
	}
	rest := text[di + len(opener):]
	q := strings.index_byte(rest, '"')
	if q < 0 {
		return "", false
	}
	return rest[:q], true
}

// The opening-lead card from a `[Play "X"]` block, if present: the first whitespace-delimited card token
// (suit letter + rank, e.g. `HK`) after the tag. `ok` is false when there is no `[Play]` tag or its first
// token does not parse as a card. The leader SEAT is not read here — set_opening_lead derives it from who
// holds the card — so the `[Play "X"]` seat annotation is not trusted.
@(private = "file")
pbn_first_play_card :: proc(text: string) -> (card: Card, ok: bool) {
	pi := strings.index(text, `[Play "`)
	if pi < 0 {
		return {}, false
	}
	rest := text[pi:]
	rb := strings.index_byte(rest, ']')
	if rb < 0 {
		return {}, false
	}
	rest = strings.trim_left_space(rest[rb + 1:]) // past the tag's closing ]
	if len(rest) < 2 {
		return {}, false
	}
	suit, sok := suit_from_letter(rest[0])
	if !sok {
		return {}, false
	}
	rank, rok := rank_from_char(rest[1])
	if !rok {
		return {}, false
	}
	return make_card(suit, rank), true
}

// Extract the deal value string from `text`: the part inside `[Deal "..."]` if that tag is present,
// otherwise the whole trimmed input (treated as a bare `N:...` value). Returns "" when a `[Deal "`
// opener has no closing quote, or the input is blank.
@(private = "file")
pbn_deal_value :: proc(text: string) -> string {
	opener :: `[Deal "`
	di := strings.index(text, opener)
	if di < 0 {
		return strings.trim_space(text)
	}
	rest := text[di + len(opener):]
	q := strings.index_byte(rest, '"')
	if q < 0 {
		return ""
	}
	return rest[:q]
}

// Parse one `S.H.D.C` hand field into a full 13-card `Hand`, recording each card in `seen` and
// rejecting duplicates. Suits are taken in SUIT_OUTPUT_ORDER (S H D C) — the order the writer emits.
@(private = "file")
parse_pbn_hand :: proc(field: string, seen: ^[DECK_SIZE]bool) -> (hand: Hand, err: Pbn_Parse_Error) {
	suit_order := SUIT_OUTPUT_ORDER // a constant cannot be indexed by a variable; copy to a local
	count := 0
	suit_index := 0
	start := 0
	for j := 0; j <= len(field); j += 1 {
		if j < len(field) && field[j] != '.' {
			continue
		}
		if suit_index >= SUIT_COUNT {
			return {}, .Bad_Suit_Count
		}
		suit := suit_order[suit_index]
		suit_index += 1
		for k := start; k < j; k += 1 {
			rank, ok := rank_from_char(field[k])
			if !ok {
				return {}, .Bad_Card
			}
			card := make_card(suit, rank)
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
		start = j + 1
	}
	if suit_index != SUIT_COUNT {
		return {}, .Bad_Suit_Count
	}
	if count != HAND_SIZE {
		return {}, .Wrong_Card_Count
	}
	return hand, .None
}
