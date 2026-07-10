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
	deal:  Deal,
	known: bit_set[Seat],
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
	return board, .None
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
