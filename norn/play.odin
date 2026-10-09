package norn

import "core:strconv"
import "core:strings"

/*
	play.odin — the cards played to a board, as a record carries them.

	A LIN record lists every card played as a run of `pc|` tokens (plus a claim, `mc|<tricks>|`); a full PBN
	record has a `[Play "<leader>"]` section and a `[Result]` tag. Both readers turn that into one `Play` on
	`Board`: the cards in the order they were played, validated against the deal.

	Validation is the point of reading the play here rather than leaving it to a viewer. Records are typed in
	by people (a vugraph operator at the table), so a card can be wrong: one the hand does not hold, one
	played out of turn, or a revoke the operator meant as something else. A bad card does not reject the
	board — the deal and the contract are still good — it CUTS THE PLAY at that card: everything before it
	is kept, `error` says why it stopped and `error_index` which card it was.

	Who played a card is not in the record (LIN) or is positional (PBN), so it is worked out the way the table
	does: the opening leader is declarer's left-hand opponent, play goes clockwise, and each trick's winner
	leads the next. That needs the trump suit and the declarer, so a play is only read for a board whose
	contract is known.
*/

PLAY_TRICKS :: 13

// Why a recorded play was cut short. `None` means every card in the record was accepted.
Play_Error :: enum {
	None,
	Bad_Card, // a token in the play did not parse as a card
	Not_Held, // the card is in no hand any more (never dealt to one, or already played)
	Out_Of_Turn, // the card is held, but by a seat that is not next to play
	Revoke, // the card does not follow suit and its holder still holds the suit led
	Too_Many, // more than 52 cards
}

// The play as the record gives it. `cards[:count]` are the accepted cards in the order played; the play may
// stop anywhere (a claim, an abandoned board, an operator error). `result` is the declaring side's TOTAL
// tricks as the record states it — a LIN claim (`mc|`) or a PBN `[Result]` — and is what the board scored
// when the play stops early.
Play :: struct {
	cards:       [DECK_SIZE]Card,
	count:       int,
	result:      Maybe(int),
	error:       Play_Error,
	error_index: int, // position in the record's card sequence of the rejected card; meaningful when error != .None
}

// One trick, its cards in the order played starting with the leader. `count` is 4 for a finished trick and
// less only for the last trick of a play that stopped part-way; `winner` is set only when the trick is
// finished.
Trick :: struct {
	leader: Seat,
	cards:  [SEAT_COUNT]Card,
	count:  int,
	winner: Maybe(Seat),
}

// The table's state part-way through a play: what each seat still holds, the trick in progress, the tricks
// finished so far and how many the declaring side has won. Built by `play_walk_start`, advanced one card at a
// time by `play_walk_card`.
Play_Walk :: struct {
	remaining:       [Seat]u64, // bit int(card) set == that seat still holds the card
	trump:           Maybe(Suit),
	declarer:        Seat,
	tricks:          [PLAY_TRICKS]Trick,
	trick_count:     int, // tricks started (the last may be unfinished)
	declarer_tricks: int, // finished tricks won by declarer or dummy
}

// The trump suit of a contract strain, nil at notrumps. `Contract_Strain`'s first four values are `Suit`'s.
strain_trump :: proc "contextless" (strain: Contract_Strain) -> Maybe(Suit) {
	if strain == .NoTrumps {
		return nil
	}
	return Suit(strain)
}

// The seat `steps` places clockwise from `seat` (Seat's backing order N E S W is clockwise).
seat_after :: proc "contextless" (seat: Seat, steps := 1) -> Seat {
	return Seat((int(seat) + steps) % SEAT_COUNT)
}

// A walk at the start of play: every hand whole, the opening lead due from declarer's left.
play_walk_start :: proc(deal: Deal, contract: Contract) -> (walk: Play_Walk) {
	for seat in Seat {
		for card in deal[seat] {
			walk.remaining[seat] |= u64(1) << u64(card)
		}
	}
	walk.trump = strain_trump(contract.strain)
	walk.declarer = contract.declarer
	return walk
}

// The seat due to play next, or nil once all 13 tricks are finished.
play_walk_next_seat :: proc(walk: ^Play_Walk) -> Maybe(Seat) {
	if walk.trick_count == 0 {
		return seat_after(walk.declarer)
	}
	last := &walk.tricks[walk.trick_count - 1]
	if last.count < SEAT_COUNT {
		return seat_after(last.leader, last.count)
	}
	if walk.trick_count == PLAY_TRICKS {
		return nil
	}
	return last.winner
}

// Play `card` from the seat due to play, or say why it cannot be. A rejected card leaves the walk unchanged.
play_walk_card :: proc(walk: ^Play_Walk, card: Card) -> Play_Error {
	seat, more := play_walk_next_seat(walk).?
	if !more {
		return .Too_Many
	}
	bit := u64(1) << u64(card)
	if walk.remaining[seat] & bit == 0 {
		for other in Seat {
			if walk.remaining[other] & bit != 0 {
				return .Out_Of_Turn
			}
		}
		return .Not_Held
	}

	// A new trick starts when the last one is finished (or none has started).
	if walk.trick_count == 0 || walk.tricks[walk.trick_count - 1].count == SEAT_COUNT {
		walk.tricks[walk.trick_count] = Trick {
			leader = seat,
		}
		walk.trick_count += 1
	}
	trick := &walk.tricks[walk.trick_count - 1]
	if trick.count > 0 {
		led := card_suit(trick.cards[0])
		if card_suit(card) != led && walk.remaining[seat] & suit_bits(led) != 0 {
			return .Revoke
		}
	}

	walk.remaining[seat] &~= bit
	trick.cards[trick.count] = card
	trick.count += 1
	if trick.count == SEAT_COUNT {
		winner := trick_winner(trick^, walk.trump)
		trick.winner = winner
		if int(winner) % 2 == int(walk.declarer) % 2 {
			walk.declarer_tricks += 1
		}
	}
	return .None
}

// The seat that wins a finished trick: the highest trump if any was played, else the highest card of the
// suit led.
trick_winner :: proc "contextless" (trick: Trick, trump: Maybe(Suit)) -> Seat {
	best := 0
	for i in 1 ..< SEAT_COUNT {
		if beats(trick.cards[i], trick.cards[best], card_suit(trick.cards[0]), trump) {
			best = i
		}
	}
	return seat_after(trick.leader, best)
}

@(private = "file")
beats :: proc "contextless" (card, best: Card, led: Suit, trump: Maybe(Suit)) -> bool {
	if t, has := trump.?; has && card_suit(card) == t && card_suit(best) != t {
		return true
	}
	if card_suit(card) != card_suit(best) {
		return false // a discard (or a non-trump against a trump) never wins
	}
	return card_rank(card) > card_rank(best)
}

// The bits of every card of `suit` in a `Play_Walk.remaining` mask.
@(private = "file")
suit_bits :: proc "contextless" (suit: Suit) -> u64 {
	bits: u64
	for rank in Rank {
		bits |= u64(1) << u64(make_card(suit, rank))
	}
	return bits
}

// Accept the cards of `sequence` in order until one is rejected. Shared by both readers.
play_from_cards :: proc(deal: Deal, contract: Contract, sequence: []Card) -> (play: Play) {
	walk := play_walk_start(deal, contract)
	for card, i in sequence {
		if err := play_walk_card(&walk, card); err != .None {
			play.error, play.error_index = err, i
			break
		}
		play.cards[play.count] = card
		play.count += 1
	}
	return play
}

// Replay a board's accepted play: its tricks in order (the last possibly unfinished) and the tricks the
// declaring side won in the finished ones.
play_tricks :: proc(deal: Deal, contract: Contract, play: Play) -> (walk: Play_Walk) {
	walk = play_walk_start(deal, contract)
	for i in 0 ..< play.count {
		err := play_walk_card(&walk, play.cards[i])
		assert(err == .None, "play_tricks: an accepted play was rejected on replay")
	}
	return walk
}

// ---------------------------------------------------------------------------------------------------
// LIN tokens

// One `key|value|` pair of a LIN record. `start` is the byte offset of the key in the text.
Lin_Token :: struct {
	key:   string,
	value: string,
	start: int,
}

// Step through a LIN record's `key|value|` pairs: `for tok in lin_next_token(text, &pos)`. Keys are trimmed
// (vugraph files put a newline before many of them); values are kept as written. A key with no closing bar
// ends the walk.
lin_next_token :: proc(text: string, pos: ^int) -> (token: Lin_Token, ok: bool) {
	if pos^ >= len(text) {
		return {}, false
	}
	rest := text[pos^:]
	key_bar := strings.index_byte(rest, '|')
	if key_bar < 0 {
		pos^ = len(text)
		return {}, false
	}
	key_start := pos^
	for key_start < pos^ + key_bar && is_lin_space(text[key_start]) {
		key_start += 1
	}
	token.key = strings.trim_space(rest[:key_bar])
	token.start = key_start
	after := rest[key_bar + 1:]
	value_bar := strings.index_byte(after, '|')
	if value_bar < 0 {
		token.value = after
		pos^ = len(text)
	} else {
		token.value = after[:value_bar]
		pos^ += key_bar + 1 + value_bar + 1
	}
	return token, true
}

@(private = "file")
is_lin_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

// The play of a LIN record: every `pc|` card in order, and the last `mc|` claim as the result. A `pc|` value
// that is not a card cuts the play there (`.Bad_Card`). nil when the record plays no card and claims nothing.
lin_play :: proc(text: string, deal: Deal, contract: Contract) -> Maybe(Play) {
	sequence: [DECK_SIZE + 1]Card
	n := 0
	bad := -1
	claim: Maybe(int)
	pos := 0
	for tok in lin_next_token(text, &pos) {
		switch tok.key {
		case "pc":
			if bad >= 0 || n == len(sequence) {
				continue
			}
			card, ok := lin_card(tok.value)
			if !ok {
				bad = n
				continue
			}
			sequence[n] = card
			n += 1
		case "mc":
			if tricks, ok := strconv.parse_int(strings.trim_space(tok.value), 10);
			   ok && tricks >= 0 && tricks <= PLAY_TRICKS {
				claim = tricks
			}
		}
	}
	if n == 0 && bad < 0 && claim == nil {
		return nil
	}
	play := play_from_cards(deal, contract, sequence[:n])
	if bad >= 0 && play.error == .None {
		play.error, play.error_index = .Bad_Card, bad
	}
	play.result = claim
	return play
}

// A LIN card: suit letter then rank character (`SA`, `hT`, `c2`), either case. A trailing alert-style `!` is
// tolerated.
lin_card :: proc "contextless" (value: string) -> (card: Card, ok: bool) {
	v := value
	for len(v) > 0 && (v[len(v) - 1] == '!' || is_lin_space(v[len(v) - 1])) {
		v = v[:len(v) - 1]
	}
	if len(v) != 2 {
		return {}, false
	}
	suit, sok := suit_from_letter(v[0])
	rank, rok := rank_from_char(v[1])
	if !sok || !rok {
		return {}, false
	}
	return make_card(suit, rank), true
}

// ---------------------------------------------------------------------------------------------------
// Vugraph files: many boards in one LIN text

// Which room of a team match a board was played in.
Room :: enum {
	Unknown,
	Open,
	Closed,
}

// Where, and by whom, a board was played, as its record names it: the board number, the room, the four
// players, and the match it belongs to. Every field is optional ("" / 0 / `.Unknown` when the record does not
// say) and a reader fills what its format carries (LIN `qx|` `ah|` `pn|` `vg|`; PBN `[Board]` `[Room]`
// `[North]`... `[Event]` `[Stage]` `[HomeTeam]` `[VisitTeam]`). The strings ALIAS the record's text, so whoever
// keeps a board keeps that text alive with it. Names are verbatim: a vugraph operator who never typed the
// closed room's names leaves "South", "West"... there, and deciding that is no name is the display's call.
Board_Table :: struct {
	number:  int,
	room:    Room,
	players: [Seat]string,
	event:   string,
	stage:   string, // the segment, round or stage within the event
	teams:   [2]string, // the two teams of a match, as listed (vugraph's first team, PBN's home team, first)
}

// One board of a multi-board LIN file. `text` runs from the board's `qx|` token to the next one (or the end)
// and is what `parse_lin_deal` reads; `table` says which board it is and who sat there (`pn|` and `vg|` come
// once, before the boards, so they reach a board only through this). All strings alias the input text.
Lin_Board_Record :: struct {
	text:  string,
	table: Board_Table,
}

// `pn|` lists names South, West, North, East: the same fixed order as `md|`. A vugraph `pn|` lists eight,
// the open room's four and then the closed room's.
@(private = "file")
LIN_PN_SEATS :: [4]Seat{.South, .West, .North, .East}

/*
Split a multi-board LIN text (a BBO vugraph segment, or several hand records pasted together) into its
boards, one per `qx|` token (`qx|o12|` = open room board 12, `c` the closed room). A text with no `qx|` at all
is ONE board, the whole text, so a single hand record goes through the same path. The returned array is the
caller's to delete; its strings alias `text`.
*/
split_lin_boards :: proc(text: string, allocator := context.allocator) -> [dynamic]Lin_Board_Record {
	boards := make([dynamic]Lin_Board_Record, allocator)
	names: [8]string
	name_count := 0
	match: Board_Table // the `vg|` header's event, stage and teams, for every board after it
	heading_number := 0 // an `ah|Board 12|` heading's number, for a record with no `qx|`
	current := -1 // index of the board being read, -1 before the first `qx|`
	current_start := 0 // byte offset of its `qx|`
	pos := 0
	for tok in lin_next_token(text, &pos) {
		switch tok.key {
		case "vg":
			match = lin_vg(tok.value)
		case "ah":
			if n, ok := lin_heading_number(tok.value); ok {
				heading_number = n
				if current >= 0 && boards[current].table.number == 0 {
					boards[current].table.number = n
				}
			}
		case "pn":
			names = {}
			name_count = 0
			rest := tok.value
			for name in strings.split_iterator(&rest, ",") {
				if name_count == len(names) {
					break
				}
				names[name_count] = strings.trim_space(name)
				name_count += 1
			}
			// A `pn|` inside a board (single hand records put it first, before `md|`) names that board's table.
			if current >= 0 {
				boards[current].table.players = lin_room_players(names[:name_count], boards[current].table.room)
			}
		case "qx":
			if current >= 0 {
				boards[current].text = text[current_start:tok.start]
			}
			table := match
			table.room, table.number = lin_qx(tok.value)
			table.players = lin_room_players(names[:name_count], table.room)
			append(&boards, Lin_Board_Record{text = text[tok.start:], table = table})
			current = len(boards) - 1
			current_start = tok.start
		}
	}
	if current < 0 {
		table := match
		table.number = heading_number
		table.players = lin_room_players(names[:name_count], .Unknown)
		append(&boards, Lin_Board_Record{text = text, table = table})
	}
	return boards
}

/*
Every board of a LIN text (see `split_lin_boards`), parsed, each carrying its `table`. On the first board that
does not parse, `err` says why and `failed` is its index; the boards before it are returned. The array is the
caller's to delete; the boards' strings alias `text`.
*/
parse_lin_boards :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	boards: [dynamic]Board,
	err: Lin_Parse_Error,
	failed: int,
) {
	records := split_lin_boards(text, context.temp_allocator)
	boards = make([dynamic]Board, allocator)
	for record, i in records {
		board, e := parse_lin_deal(record.text)
		if e != .None {
			return boards, e, i
		}
		board.table = record.table
		append(&boards, board)
	}
	return boards, .None, -1
}

@(private = "file")
lin_room_players :: proc(names: []string, room: Room) -> (players: [Seat]string) {
	seats := LIN_PN_SEATS
	offset := 0
	if room == .Closed && len(names) >= 8 {
		offset = 4
	}
	for seat, i in seats {
		if offset + i < len(names) {
			players[seat] = names[offset + i]
		}
	}
	return players
}

// Read a `qx|` value: `o12` / `c12` (room + board number). Any other leading letter, or none, is `.Unknown`.
@(private = "file")
lin_qx :: proc(value: string) -> (room: Room, number: int) {
	v := strings.trim_space(value)
	if len(v) > 0 {
		switch v[0] {
		case 'o', 'O':
			room = .Open
			v = v[1:]
		case 'c', 'C':
			room = .Closed
			v = v[1:]
		}
	}
	if n, ok := strconv.parse_int(v, 10); ok && n > 0 {
		number = n
	}
	return room, number
}

// Read a vugraph `vg|` header: `event,stage,scoring,first board,last board,team 1,carry-over,team 2,carry-over`.
@(private = "file")
lin_vg :: proc(value: string) -> (table: Board_Table) {
	rest := value
	i := 0
	for field in strings.split_iterator(&rest, ",") {
		f := strings.trim_space(field)
		switch i {
		case 0:
			table.event = f
		case 1:
			table.stage = f
		case 5:
			table.teams[0] = f
		case 7:
			table.teams[1] = f
		}
		i += 1
	}
	return table
}

// The number an `ah|` heading (`Board 12`) ends with.
@(private = "file")
lin_heading_number :: proc(value: string) -> (number: int, ok: bool) {
	v := strings.trim_space(value)
	start := len(v)
	for start > 0 && v[start - 1] >= '0' && v[start - 1] <= '9' {
		start -= 1
	}
	n, parsed := strconv.parse_int(v[start:], 10)
	return n, parsed && n > 0
}
