#+build !js
package norn

import "core:strings"
import "core:testing"

// A real BBO vugraph segment (archive id 87351: 16 boards, open and closed rooms, every board ending in a
// claim, one claim part-way through a trick). Fetched once from bridgebase.com's vugraph archive.
@(private = "file")
VUGRAPH :: #load("testdata/vugraph-87351.lin", string)

// Board 13, open room, by itself: 2♦ by West, North leads, a claim of 7 after trick 8's first card.
@(private = "file")
O13 :: "md|3SKT87HT2DJ3CQT754,SAJ3HK4DKQ9852C98,S42HAQ986DAT74CA6,SQ965HJ753D6CKJ32|sv|b|mb|1H|mb|p|mb|p|mb|2D|mb|p|mb|p|mb|p|pc|s4|pc|s5|pc|sK|pc|sA|pc|dQ|pc|d4|pc|d6|pc|d3|pc|d8|pc|d7|pc|h3|pc|dJ|pc|h2|pc|h4|pc|hQ|pc|h5|pc|cA|pc|c2|pc|c4|pc|c8|pc|hA|pc|h7|pc|hT|pc|hK|pc|h9|pc|hJ|pc|c5|pc|c9|pc|c3|mc|7|"

@(private = "file")
card_of :: proc(text: string) -> Card {
	card, ok := lin_card(text)
	assert(ok)
	return card
}

// The segment splits into its 16 boards, each with its room, board number and that room's four names.
@(test)
test_split_vugraph_segment :: proc(t: ^testing.T) {
	records := split_lin_boards(VUGRAPH)
	defer delete(records)
	testing.expect_value(t, len(records), 16)

	first := records[0]
	testing.expect_value(t, first.table.room, Room.Open)
	testing.expect_value(t, first.table.number, 13)
	testing.expect_value(t, first.table.players[.South], "JONI")
	testing.expect_value(t, first.table.players[.West], "ANDRI")
	testing.expect_value(t, first.table.players[.North], "BG PIT")
	testing.expect_value(t, first.table.players[.East], "WEWEN")
	testing.expect(t, strings.has_prefix(first.text, "qx|o13|"))
	testing.expect(t, !strings.contains(first.text, "qx|c13|"))

	// The closed room takes the second four names.
	testing.expect_value(t, records[1].table.room, Room.Closed)
	testing.expect_value(t, records[1].table.number, 13)
	testing.expect_value(t, records[1].table.players[.South], "South")

	last := records[len(records) - 1]
	testing.expect_value(t, last.table.room, Room.Open)
	testing.expect_value(t, last.table.number, 22)
}

// Every board of the real segment reads with its contract and its whole recorded play: all 361 `pc|` cards
// are accepted (the operators made no error a reader can see), and every board carries its claim.
@(test)
test_vugraph_plays_are_accepted :: proc(t: ^testing.T) {
	records := split_lin_boards(VUGRAPH)
	defer delete(records)
	total := 0
	for record in records {
		board, err := parse_lin_deal(record.text)
		testing.expect_value(t, err, Lin_Parse_Error.None)
		_, has_contract := board.contract.?
		testing.expect(t, has_contract)
		play, has_play := board.play.?
		testing.expect(t, has_play)
		testing.expect_value(t, play.error, Play_Error.None)
		_, has_result := play.result.?
		testing.expect(t, has_result)
		total += play.count
	}
	testing.expect_value(t, total, 361)
}

// Who led each trick and who won it follows from the contract: North leads against 2♦ by West, West's ♠A
// wins trick 1, South's ♦J overtakes West's ♦8 in trick 3, and so on.
@(test)
test_lin_play_tricks :: proc(t: ^testing.T) {
	board, err := parse_lin_deal(O13)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	contract := board.contract.?
	play := board.play.?
	testing.expect_value(t, play.count, 29)
	testing.expect_value(t, play.result, 7)

	walk := play_tricks(board.deal, contract, play)
	testing.expect_value(t, walk.trick_count, 8)
	Expect :: struct {
		leader, winner: Seat,
	}
	expected := [7]Expect {
		{.North, .West}, // ♠4 5 K A
		{.West, .West}, // ♦Q 4 6 3
		{.West, .South}, // ♦8 7, ♥3 discard, ♦J
		{.South, .North}, // ♥2 4 Q 5
		{.North, .North}, // ♣A 2 4 8
		{.North, .North}, // ♥A 7 T K
		{.North, .East}, // ♥9 J, ♣5, ♣9: no trump played, the ♥J wins
	}
	for e, i in expected {
		testing.expect_value(t, walk.tricks[i].leader, e.leader)
		testing.expect_value(t, walk.tricks[i].winner, e.winner)
	}
	// Trick 8 stopped at its first card: East's ♣3, unfinished.
	last := walk.tricks[7]
	testing.expect_value(t, last.leader, Seat.East)
	testing.expect_value(t, last.count, 1)
	testing.expect_value(t, last.cards[0], card_of("c3"))
	_, finished := last.winner.?
	testing.expect(t, !finished)
	testing.expect_value(t, walk.declarer_tricks, 3)
}

// A claim in the middle of a trick keeps the cards played to it.
@(test)
test_lin_claim_mid_trick :: proc(t: ^testing.T) {
	records := split_lin_boards(VUGRAPH)
	defer delete(records)
	board, _ := parse_lin_deal(records[5].text) // closed room board 15: three cards, then `mc|13|`
	play := board.play.?
	testing.expect_value(t, play.count, 3)
	testing.expect_value(t, play.result, 13)
	walk := play_tricks(board.deal, board.contract.?, play)
	testing.expect_value(t, walk.trick_count, 1)
	testing.expect_value(t, walk.tricks[0].count, 3)
}

// An operator error cuts the play at the bad card, keeps the board and says why and where.
@(test)
test_lin_bad_card_cuts_the_play :: proc(t: ^testing.T) {
	Case :: struct {
		from, to: string,
		error:    Play_Error,
		index:    int,
	}
	cases := [?]Case {
		{"pc|s5|", "pc|s3|", .Out_Of_Turn, 1}, // ♠3 is West's, East is to play
		{"pc|s5|", "pc|h3|", .Revoke, 1}, // East still holds spades
		{"pc|dQ|", "pc|sK|", .Not_Held, 4}, // the ♠K went in trick 1
		{"pc|dQ|", "pc|zz|", .Bad_Card, 4},
	}
	for c in cases {
		text, _ := strings.replace(O13, c.from, c.to, 1, context.temp_allocator)
		board, err := parse_lin_deal(text)
		testing.expect_value(t, err, Lin_Parse_Error.None)
		play, has := board.play.?
		testing.expect(t, has)
		testing.expect_value(t, play.error, c.error)
		testing.expect_value(t, play.error_index, c.index)
		testing.expect_value(t, play.count, c.index)
		testing.expect_value(t, play.result, 7)
	}
}

// No auction, no contract: the play cannot be attributed, so none is read (the opening lead still is).
@(test)
test_lin_play_needs_a_contract :: proc(t: ^testing.T) {
	text := "md|3SKT87HT2DJ3CQT754,SAJ3HK4DKQ9852C98,S42HAQ986DAT74CA6,SQ965HJ753D6CKJ32|pc|s4|pc|s5|"
	board, err := parse_lin_deal(text)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	_, has_play := board.play.?
	testing.expect(t, !has_play)
	_, has_lead := board.opening_lead.?
	testing.expect(t, has_lead)
}

// The same board as a PBN record. The `[Play]` columns are FIXED seats (N E S W, from the tag's seat) and do
// not rotate to each trick's leader — trick 2 is led by West, so its first card is in the LAST column — and
// the reader recovers exactly the order the LIN record gives. Comments, a NAG and a note reference are
// skipped; `-` ends the play part-way through trick 8; `*` ends the section.
@(test)
test_pbn_play_matches_lin :: proc(t: ^testing.T) {
	lin_board, _ := parse_lin_deal(O13)
	b := strings.builder_make(context.temp_allocator)
	render_deal_pbn(&b, lin_board.deal)
	strings.write_string(
		&b,
		`
[Contract "2D"]
[Declarer "W"]
[Result "7"]
[Play "N"]
S4 S5 SK SA
D4 D6 D3 DQ {West led the queen}
D7 H3 DJ D8
HQ H5 H2 H4 $1
CA C2 C4 C8
HA H7 HT HK =1=
H9 HJ C5 C9
-  C3 -  -
*
[Note "1:a comment"]
`,
	)
	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	play, has := board.play.?
	testing.expect(t, has)
	testing.expect_value(t, play.error, Play_Error.None)
	testing.expect_value(t, play.result, 7)
	lin_play := lin_board.play.?
	testing.expect_value(t, play.count, lin_play.count)
	for i in 0 ..< lin_play.count {
		testing.expect_value(t, play.cards[i], lin_play.cards[i])
	}
}

// A PBN record whose columns were (wrongly) rotated to each trick's leader is caught, not misread: trick 2
// written leader-first puts West's ♦Q in North's column.
@(test)
test_pbn_rotated_columns_are_rejected :: proc(t: ^testing.T) {
	lin_board, _ := parse_lin_deal(O13)
	b := strings.builder_make(context.temp_allocator)
	render_deal_pbn(&b, lin_board.deal)
	strings.write_string(&b, "\n[Contract \"2D\"]\n[Declarer \"W\"]\n[Play \"N\"]\nS4 S5 SK SA\nDQ D4 D6 D3\n*\n")
	board, _ := parse_pbn_deal(strings.to_string(b))
	play := board.play.?
	testing.expect_value(t, play.count, 4)
	testing.expect_value(t, play.error, Play_Error.Out_Of_Turn)
	testing.expect_value(t, play.error_index, 4)
}

// Trick winners: a trump beats any card of the suit led; a discard never wins; at notrumps the highest card
// of the suit led wins.
@(test)
test_trick_winner :: proc(t: ^testing.T) {
	trick := Trick {
		leader = .East,
		cards  = {card_of("hK"), card_of("hA"), card_of("s2"), card_of("cA")},
		count  = 4,
	}
	testing.expect_value(t, trick_winner(trick, Suit.Spades), Seat.West) // ♠2 ruffs
	testing.expect_value(t, trick_winner(trick, nil), Seat.South) // ♥A
	testing.expect_value(t, trick_winner(trick, Suit.Diamonds), Seat.South)
}

// The vugraph header and the room's names reach every parsed board: event, segment, both teams, the board
// number and room from `qx|`, and the open room's players (the closed room's operator typed only seat names).
@(test)
test_parse_lin_boards_carry_the_table :: proc(t: ^testing.T) {
	boards, err, failed := parse_lin_boards(VUGRAPH)
	defer delete(boards)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect_value(t, failed, -1)
	testing.expect_value(t, len(boards), 16)
	open := boards[0].table
	testing.expect_value(t, open.number, 13)
	testing.expect_value(t, open.room, Room.Open)
	testing.expect_value(t, open.event, "PORPROV SUMBAR X16 2026")
	testing.expect_value(t, open.stage, "RR1-2")
	testing.expect_value(t, open.teams[0], "KAB TANAH DATAR")
	testing.expect_value(t, open.teams[1], "KOTA  PADANG")
	testing.expect_value(t, open.players[.North], "BG PIT")
	closed := boards[1].table
	testing.expect_value(t, closed.room, Room.Closed)
	testing.expect_value(t, closed.players[.North], "North")
	testing.expect_value(t, closed.event, open.event)
}

// A single hand record: `pn|` names its table, an `ah|Board 7|` heading its number.
@(test)
test_single_lin_record_table :: proc(t: ^testing.T) {
	rec := "pn|Sam,Wes,Nat,Eve|st||md|3SKT87HT2DJ3CQT754,SAJ3HK4DKQ9852C98,S42HAQ986DAT74CA6,SQ965HJ753D6CKJ32|sv|b|ah|Board 7|"
	boards, err, _ := parse_lin_boards(rec)
	defer delete(boards)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect_value(t, len(boards), 1)
	table := boards[0].table
	testing.expect_value(t, table.number, 7)
	testing.expect_value(t, table.room, Room.Unknown)
	testing.expect_value(t, table.players[.South], "Sam")
	testing.expect_value(t, table.players[.East], "Eve")
}

// PBN's identity tags: board, room, the four names, event, stage and the two teams.
@(test)
test_pbn_table_tags :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"[Event \"Spring Teams\"]\n[Stage \"Final\"]\n[Board \"12\"]\n[West \"Wes\"]\n[North \"Nat\"]\n[East \"Eve\"]\n[South \"Sam\"]\n[HomeTeam \"Lions\"]\n[VisitTeam \"Tigers\"]\n[Room \"Closed\"]\n",
	)
	render_deal_pbn(&b, deal_from_deck(full_deck()))
	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	table := board.table
	testing.expect_value(t, table.number, 12)
	testing.expect_value(t, table.room, Room.Closed)
	testing.expect_value(t, table.players[.West], "Wes")
	testing.expect_value(t, table.event, "Spring Teams")
	testing.expect_value(t, table.stage, "Final")
	testing.expect_value(t, table.teams[1], "Tigers")
}
