package norn

import "core:strings"
import "core:testing"

// The core auction rule: the declarer is the FIRST player of the contracting side to have named the
// final denomination, not merely whoever made the last bid. Dealer North; North opens 1D, South bids 1H,
// North later rebids 2H — the final contract is 2H by the N/S side, so declarer is SOUTH (first to name
// hearts), even though NORTH made the last hearts bid.
@(test)
test_derive_contract_first_namer :: proc(t: ^testing.T) {
	calls := []string{"1D", "p", "1H", "p", "2H", "p", "p", "p"}
	level, strain, declarer, ok := derive_contract(.North, calls)
	testing.expect(t, ok)
	testing.expect_value(t, level, 2)
	testing.expect_value(t, strain, Contract_Strain.Hearts)
	testing.expect_value(t, declarer, Seat.South)
}

// A simple uncontested auction: dealer North opens 1S, South raises to 2S, passed out. North named spades
// first, so North declares 2S.
@(test)
test_derive_contract_opener_declares :: proc(t: ^testing.T) {
	calls := []string{"1S", "p", "2S", "p", "p", "p"}
	level, strain, declarer, ok := derive_contract(.North, calls)
	testing.expect(t, ok)
	testing.expect_value(t, level, 2)
	testing.expect_value(t, strain, Contract_Strain.Spades)
	testing.expect_value(t, declarer, Seat.North)
}

// Notrump and doubles: dealer East opens 1NT, South overcalls 2C, West doubles, North bids 3NT, passed
// out. Rotation from East is E,S,W,N,E,S,W — so the 3NT bidder (i3) is North. Final 3NT by the N/S side;
// North named notrump first, so North declares. The double (i2) is a call but changes no denomination.
@(test)
test_derive_contract_notrump_and_double :: proc(t: ^testing.T) {
	calls := []string{"1N", "2C", "d", "3NT", "p", "p", "p"}
	level, strain, declarer, ok := derive_contract(.East, calls)
	testing.expect(t, ok)
	testing.expect_value(t, level, 3)
	testing.expect_value(t, strain, Contract_Strain.NoTrump)
	testing.expect_value(t, declarer, Seat.North)
}

// A passed-out auction (all passes) names no contract.
@(test)
test_derive_contract_passed_out :: proc(t: ^testing.T) {
	calls := []string{"p", "p", "p", "p"}
	_, _, _, ok := derive_contract(.North, calls)
	testing.expect(t, !ok)
}

// A LIN record with an `mb|` auction fills in the contract: dealer digit 3 = North, North opens 1S, South
// raises to 2S, passed out -> 2S by North.
@(test)
test_parse_lin_contract_from_auction :: proc(t: ^testing.T) {
	rec := "md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|mb|1S|mb|p|mb|2S|mb|p|mb|p|mb|p|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect(t, board.has_contract)
	testing.expect_value(t, board.contract_level, 2)
	testing.expect_value(t, board.contract_strain, Contract_Strain.Spades)
	testing.expect_value(t, board.declarer, Seat.North)
}

// No `mb|` auction -> no contract recorded (the deal still parses).
@(test)
test_parse_lin_no_auction :: proc(t: ^testing.T) {
	rec := "md|3SAKTHK96DKT65C973,SQ875HAQT4D97CKT5,S962H8752DQJ83CA6,SJ43HJ3DA42CQJ842|sv|o|"
	board, err := parse_lin_deal(rec)
	testing.expect_value(t, err, Lin_Parse_Error.None)
	testing.expect(t, !board.has_contract)
}

// PBN `[Contract]` + `[Declarer]` tags fill in the contract; a trailing doubling marker is ignored.
@(test)
test_parse_pbn_contract_tags :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render_deal_pbn(&b, deal_from_deck(full_deck()))
	strings.write_string(&b, `[Contract "4HX"]`)
	strings.write_string(&b, `[Declarer "S"]`)

	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect(t, board.has_contract)
	testing.expect_value(t, board.contract_level, 4)
	testing.expect_value(t, board.contract_strain, Contract_Strain.Hearts)
	testing.expect_value(t, board.declarer, Seat.South)
}

// `[Contract]` without a `[Declarer]` tag leaves the contract unset — the declaring side is unknown.
@(test)
test_parse_pbn_contract_needs_declarer :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	render_deal_pbn(&b, deal_from_deck(full_deck()))
	strings.write_string(&b, `[Contract "3NT"]`)

	board, err := parse_pbn_deal(strings.to_string(b))
	testing.expect_value(t, err, Pbn_Parse_Error.None)
	testing.expect(t, !board.has_contract)
}
