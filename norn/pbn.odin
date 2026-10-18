package norn

import "core:strconv"
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
Board :: struct {
	deal:         Deal,
	known:        bit_set[Seat],
	// The recorded opening lead, when the source carried a play sequence (LIN `pc|`, PBN `[Play]`) and its
	// leader is identifiable: the seat holding the card in a full deal; on a 2-hand board, an UNKNOWN seat named
	// by the `[Play "<seat>"]` tag (else the declarer's left-hand opponent) whose card no known hand holds - the
	// card the advisor then knows that defender held. nil otherwise.
	opening_lead: Maybe(Opening_Lead),
	// The contract the record names, or nil when it names none — a bare `[Deal]` tag, a passed-out auction,
	// or a 2-hand OCR board with no metadata. LIN: derived from the `mb|` auction (final bid + the
	// rule-correct declarer). PBN: from `[Contract]` + `[Declarer]` tags.
	contract:     Maybe(Contract),
	// The cards played, when the record carries them AND names the contract (who plays each card follows
	// from the declarer and the trump suit) AND gives all four hands. LIN: the `pc|` tokens plus an `mc|`
	// claim; PBN: the `[Play]` section plus `[Result]`. A bad card cuts the play there (see play.odin).
	play:         Maybe(Play),
	// Which board, which room, who played it and in what match, as far as the record says (`Board_Table`).
	table:        Board_Table,
	// The dealer and the vulnerability the record gives: LIN's `md|` dealer digit and `sv|`, PBN's `[Dealer]` and
	// `[Vulnerable]`. A record that names neither leaves no dealer and nobody vulnerable.
	conditions:   Table,
}

// An opening lead: the card led and the seat that led it. One value rather than two loose fields because
// neither half means anything without the other.
Opening_Lead :: struct {
	card:   Card,
	leader: Seat,
}

// Record `card` as the board's opening lead: find the KNOWN seat that holds it and mark it the leader. A
// no-op (`opening_lead` stays nil) when the card is in no known hand — e.g. a 2-hand board whose lead
// belongs to an unspecified defender. Called by the LIN / PBN readers once the deal is built.
set_opening_lead :: proc(board: ^Board, card: Card) {
	for seat in board.known {
		for c in board.deal[seat] {
			if c == card {
				board.opening_lead = Opening_Lead {
					card   = card,
					leader = seat,
				}
				return
			}
		}
	}
}

// A 2-hand board's opening lead, whose card is in no known hand: its leader is the seat the `[Play]` tag names,
// else the declarer's left-hand opponent - and must be one of the unknown seats.
@(private = "file")
set_defender_lead :: proc(board: ^Board, card: Card, text: string) {
	leader: Seat
	if v, ok := pbn_tag_value(text, "Play"); ok && len(v) >= 1 {
		seat, sok := seat_from_letter(v[0])
		if !sok {
			return
		}
		leader = seat
	} else if contract, has := board.contract.?; has {
		leader = Seat((int(contract.declarer) + 1) % SEAT_COUNT)
	} else {
		return
	}
	if leader in board.known {
		return
	}
	board.opening_lead = Opening_Lead {
		card   = card,
		leader = leader,
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

// Parse a PBN `[Deal]` tag into a `Board`. `text` may be a whole line containing the tag
// (`[Deal "N:..."]`, with any surrounding text ignored) or the bare deal value (`N:...`). On failure
// the returned board is zero and `err` says why. The parse is strict: exactly four hand fields, each
// either `-` (unknown) or a full 13-card `S.H.D.C` hand, all cards across the board distinct.
parse_pbn_deal :: proc(text: string) -> (board: Board, err: Pbn_Parse_Error) {
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
	first_card, has_first_card := pbn_first_play_card(text)
	if has_first_card {
		set_opening_lead(&board, first_card)
	}
	// The contract, when the record carried both `[Contract]` and `[Declarer]` (a full PBN record, or the
	// hand-ocr replay metadata). Both are required: the declarer fixes the declaring side. Absent or a
	// passed-out `[Contract "Pass"]` leaves `contract` nil.
	if lvl, strain, doubling, cok := pbn_contract(text); cok {
		if declarer, dok := pbn_declarer(text); dok {
			board.contract = Contract {
				level    = lvl,
				strain   = strain,
				declarer = declarer,
				doubling = doubling,
			}
		}
	}
	if contract, has := board.contract.?; has && board.known == {.North, .East, .South, .West} {
		board.play = pbn_play(text, board.deal, contract)
	}
	if has_first_card && board.opening_lead == nil {
		set_defender_lead(&board, first_card, text)
	}
	board.table = pbn_table(text)
	board.conditions = pbn_conditions(text)
	return board, .None
}

// The `[Dealer]` and `[Vulnerable]` tags. `[Vulnerable]` is `None`/`Love`/`-`, `NS`, `EW`, `All`/`Both`; an unknown
// value reads as nobody vulnerable.
@(private = "file")
pbn_conditions :: proc(text: string) -> (table: Table) {
	if v, ok := pbn_tag_value(text, "Dealer"); ok && len(v) >= 1 {
		if seat, sok := seat_from_letter(v[0]); sok {
			table.dealer = seat
		}
	}
	if v, ok := pbn_tag_value(text, "Vulnerable"); ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "ns":
			table.vulnerability = .North_South
		case "ew":
			table.vulnerability = .East_West
		case "all", "both":
			table.vulnerability = .Both
		}
	}
	return table
}

// The board's identity tags: `[Board]`, `[Room]`, the four seats' names, `[Event]`, `[Stage]` (else `[Round]`),
// `[HomeTeam]`, `[VisitTeam]`. Missing tags leave their fields empty.
@(private = "file")
pbn_table :: proc(text: string) -> (table: Board_Table) {
	if v, ok := pbn_tag_value(text, "Board"); ok {
		if n, nok := strconv.parse_int(strings.trim_space(v), 10); nok && n > 0 {
			table.number = n
		}
	}
	if v, ok := pbn_tag_value(text, "Room"); ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "open":
			table.room = .Open
		case "closed":
			table.room = .Closed
		}
	}
	SEAT_TAGS :: [Seat]string {
		.North = "North",
		.East  = "East",
		.South = "South",
		.West  = "West",
	}
	tags := SEAT_TAGS
	for seat in Seat {
		table.players[seat], _ = pbn_tag_value(text, tags[seat])
	}
	table.event, _ = pbn_tag_value(text, "Event")
	if v, ok := pbn_tag_value(text, "Stage"); ok && v != "" {
		table.stage = v
	} else {
		table.stage, _ = pbn_tag_value(text, "Round")
	}
	table.teams[0], _ = pbn_tag_value(text, "HomeTeam")
	table.teams[1], _ = pbn_tag_value(text, "VisitTeam")
	return table
}

/*
The play from a `[Play "<seat>"]` section, and the declaring side's tricks from `[Result]`. nil when there is
no `[Play]` tag and no result.

Each line of the section is one trick and each COLUMN one seat, in a fixed order starting from the tag's seat
(the opening leader). The columns do not rotate to each trick's leader, so the order a trick was played in is
worked out from who won the trick before. `-` is a card not played (the play stopped); `*` ends the section.
Comments (`{…}`, `;` to end of line) and annotations (`$n` NAGs, `=n=` note references, `^n` irregularity
marks) are skipped, as is a `!`/`?` suffix on a card.
*/
@(private = "file")
pbn_play :: proc(text: string, deal: Deal, contract: Contract) -> Maybe(Play) {
	result: Maybe(int)
	if val, found := pbn_tag_value(text, "Result"); found {
		if n, ok := strconv.parse_int(strings.trim_space(val), 10); ok && n >= 0 && n <= PLAY_TRICKS {
			result = n
		}
	}
	seat_val, found := pbn_tag_value(text, "Play")
	first_column := Seat.North // the seat of the section's first column
	sok := false
	if len(seat_val) > 0 {
		first_column, sok = seat_from_letter(seat_val[0])
	}
	if !found || !sok {
		if result == nil {
			return nil
		}
		return Play{result = result}
	}

	// The section's tokens in order, four to a row: a card, `-` (not played), or something unreadable.
	Slot :: struct {
		card:   Card,
		played: bool,
		bad:    bool,
	}
	slots: [DECK_SIZE]Slot
	slot_count := 0
	body := text[strings.index(text, `[Play "`):]
	body = body[strings.index_byte(body, ']') + 1:]
	scan: for i := 0; i < len(body) && slot_count < len(slots); {
		c := body[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i += 1
		case c == '{':
			close := strings.index_byte(body[i:], '}')
			i = close < 0 ? len(body) : i + close + 1
		case c == ';':
			eol := strings.index_byte(body[i:], '\n')
			i = eol < 0 ? len(body) : i + eol + 1
		case c == '[' || c == '*':
			break scan
		case:
			end := i
			for end < len(body) && !strings.contains_rune(" \t\r\n{;[", rune(body[end])) {
				end += 1
			}
			tok := body[i:end]
			i = end
			switch tok[0] {
			case '$', '=', '^':
				continue scan // an annotation, not a card
			case '-':
				slots[slot_count] = {}
			case:
				for len(tok) > 2 && (tok[len(tok) - 1] == '!' || tok[len(tok) - 1] == '?') {
					tok = tok[:len(tok) - 1]
				}
				card, ok := lin_card(tok) // PBN writes a card suit-first too: `SA`, `HT`
				slots[slot_count] = {card, ok, !ok}
			}
			slot_count += 1
		}
	}

	play := Play {
		result = result,
	}
	walk := play_walk_start(deal, contract)
	rows: for row := 0; row * SEAT_COUNT < slot_count; row += 1 {
		leader, more := play_walk_next_seat(&walk).?
		if !more {
			break
		}
		for k in 0 ..< SEAT_COUNT {
			column := (int(leader) + k - int(first_column) + SEAT_COUNT) % SEAT_COUNT
			index := row * SEAT_COUNT + column
			if index >= slot_count || !slots[index].played {
				if index < slot_count && slots[index].bad {
					play.error, play.error_index = .Bad_Card, play.count
				}
				break rows
			}
			card := slots[index].card
			if err := play_walk_card(&walk, card); err != .None {
				play.error, play.error_index = err, play.count
				break rows
			}
			play.cards[play.count] = card
			play.count += 1
		}
	}
	return play
}

// The contract from a `[Contract "..."]` tag: level 1..7, denomination and doubling (`4H`, `3NT`, `4SX`,
// `6NTXX`). ok=false when the tag is absent, is `Pass`/empty, or otherwise malformed.
@(private = "file")
pbn_contract :: proc(text: string) -> (level: int, strain: Contract_Strain, doubling: Doubling, ok: bool) {
	val, found := pbn_tag_value(text, "Contract")
	if !found || len(val) < 2 {
		return 0, .NoTrumps, .None, false
	}
	if val[0] < '1' || val[0] > '7' {
		return 0, .NoTrumps, .None, false
	}
	denom := val[1:]
	xs := 0
	for len(denom) > 0 && (denom[len(denom) - 1] == 'X' || denom[len(denom) - 1] == 'x') {
		denom = denom[:len(denom) - 1]
		xs += 1
	}
	s, sok := contract_strain_from_token(denom)
	if !sok || xs > 2 {
		return 0, .NoTrumps, .None, false
	}
	return int(val[0] - '0'), s, Doubling(xs), true
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
