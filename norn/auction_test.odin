#+build !js
package norn

import "core:testing"

@(private = "file")
LIN_WITH_NOTES :: "pn|A,B,C,D|st||md|3SKT87HT2DJ3CQT754,SAJ3HK4DKQ9852C98,S42HAQ986DAT74CA6,SQ965HJ753D6CKJ32|sv|b|" +
	"nt|North deals: a quiet start, or is it? Tomb|" +
	"mb|1H|mb|p|mb|1S|mb|2D!|an|both minors|mb|p|nt|South could raise here|mb|p|mb|p|" +
	"pc|s4|pc|sQ|pc|sK|pc|sA|nt|A good start|pc|c9|mc|6|"

// A LIN record's calls, its alert and explanation, and its comments placed after the calls and cards before them.
@(test)
test_a_lin_auction_keeps_its_alerts_and_comments :: proc(t: ^testing.T) {
	board, err := parse_lin_deal(LIN_WITH_NOTES)
	if !testing.expect_value(t, err, Lin_Parse_Error.None) {return}
	auction, has := board.auction.?
	if !testing.expect(t, has, "the record has an auction") {return}
	testing.expect_value(t, auction.dealer, Seat.North)
	testing.expect_value(t, auction.count, 7)
	testing.expect_value(t, auction.cut, false)
	two_diamonds := auction.calls[3]
	testing.expect_value(t, two_diamonds.kind, Call_Kind.Bid)
	testing.expect_value(t, two_diamonds.level, 2)
	testing.expect_value(t, two_diamonds.strain, Contract_Strain.Diamonds)
	testing.expect(t, two_diamonds.alerted, "2D! is alerted")
	testing.expect_value(t, two_diamonds.explanation, "both minors")
	testing.expect_value(t, call_seat(auction, 3), Seat.West)
	testing.expect_value(t, auction.calls[1].kind, Call_Kind.Pass)
	testing.expect(t, !auction.calls[0].alerted, "1H is not alerted")

	testing.expect_value(t, board.commentary.count, 3)
	first := board.commentary.comments[0]
	testing.expect_value(t, first.text, "North deals: a quiet start, or is it? Tomb")
	testing.expect_value(t, first.calls, 0)
	middle := board.commentary.comments[1]
	testing.expect_value(t, middle.calls, 5)
	testing.expect_value(t, middle.cards, 0)
	last := board.commentary.comments[2]
	testing.expect_value(t, last.calls, 7)
	testing.expect_value(t, last.cards, 4)

	// The contract and the play still read, and a comment's text is never taken for a call.
	contract, cok := board.contract.?
	testing.expect(t, cok, "the auction names a contract")
	testing.expect_value(t, contract, Contract{level = 2, strain = .Diamonds, declarer = .West})
	play, pok := board.play.?
	testing.expect(t, pok, "the play is read")
	testing.expect_value(t, play.count, 5)
	lead, lok := board.opening_lead.?
	testing.expect(t, lok && lead.leader == .North, "North leads")
}

@(private = "file")
PBN_WITH_NOTES :: `% PBN 2.1
{A deal from the club's Tuesday game.}
[Board "7"]
[Dealer "S"]
[Vulnerable "All"]
[Deal "N:AQ43.K72.K84.Q53 T82.QJ95.QT92.84 KJ965.A4.A73.K62 7.T863.J65.AJT97"]
[Auction "S"]
1S Pass 2NT =1= Pass
3C =2= $1 Pass 4S AP
{Not everyone would bid 4S here.}
[Note "1:Jacoby, a game force with four spades"]
[Note "2:a shortage"]
[Contract "4S"]
[Declarer "S"]
[Play "W"]
CA C3 C4 C2
{West cashed the CA and went on.}
C7 C5 C8 CK
*
[Result "11"]
`

// A PBN board's auction section: its calls, `AP`, the notes its `=n=` references name, and the comments around it.
@(test)
test_a_pbn_auction_keeps_its_notes_and_comments :: proc(t: ^testing.T) {
	board, err := parse_pbn_deal(PBN_WITH_NOTES)
	if !testing.expect_value(t, err, Pbn_Parse_Error.None) {return}
	auction, has := board.auction.?
	if !testing.expect(t, has, "the board has an auction") {return}
	testing.expect_value(t, auction.dealer, Seat.South)
	testing.expect_value(t, auction.count, 10) // 1S P 2NT P 3C P 4S, then three passes
	testing.expect_value(t, auction.calls[2].explanation, "Jacoby, a game force with four spades")
	testing.expect(t, auction.calls[2].alerted, "a call with a note is explained")
	testing.expect_value(t, auction.calls[4].explanation, "a shortage")
	testing.expect_value(t, auction.calls[6].level, 4)
	testing.expect_value(t, auction.calls[9].kind, Call_Kind.Pass)
	testing.expect_value(t, auction.calls[3].explanation, "")

	testing.expect_value(t, board.commentary.count, 3)
	testing.expect_value(t, board.commentary.comments[0].text, "A deal from the club's Tuesday game.")
	testing.expect_value(t, board.commentary.comments[0].calls, 0)
	testing.expect_value(t, board.commentary.comments[1].calls, 10)
	testing.expect_value(t, board.commentary.comments[1].cards, 0)
	testing.expect_value(t, board.commentary.comments[2].text, "West cashed the CA and went on.")
	testing.expect_value(t, board.commentary.comments[2].cards, 4)

	play, pok := board.play.?
	testing.expect(t, pok && play.count == 8, "the play still reads past its comment")
}

// A PBN board with an auction and no `[Contract]` tag takes the contract the auction reaches; one with neither has
// no auction and no commentary.
@(test)
test_a_pbn_auction_names_the_contract :: proc(t: ^testing.T) {
	text := `[Deal "N:AQ43.K72.K84.Q53 T82.QJ95.QT92.84 KJ965.A4.A73.K62 7.T863.J65.AJT97"]
[Auction "N"]
Pass 1C 1S X
2S Pass Pass XX
AP`
	board, _ := parse_pbn_deal(text)
	contract, has := board.contract.?
	testing.expect(t, has, "the auction reaches a contract")
	testing.expect_value(t, contract, Contract{level = 2, strain = .Spades, declarer = .South, doubling = .Redoubled})

	bare, _ := parse_pbn_deal(`N:AQ43.K72.K84.Q53 T82.QJ95.QT92.84 KJ965.A4.A73.K62 7.T863.J65.AJT97`)
	testing.expect_value(t, bare.auction, nil)
	testing.expect_value(t, bare.commentary.count, 0)

	passed, _ := parse_pbn_deal(`[Deal "N:AQ43.K72.K84.Q53 T82.QJ95.QT92.84 KJ965.A4.A73.K62 7.T863.J65.AJT97"][Auction "E"]AP`)
	auction, ok := passed.auction.?
	testing.expect(t, ok && auction.count == 4, "a passed-out auction is four passes")
	testing.expect_value(t, passed.contract, nil)
}
