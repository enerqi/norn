package norn

/*
	render_test.odin — golden-output tests for the text renderers.

	These tests build boards deterministically (no RNG) so the exact expected text can be asserted.
*/

import "core:math/rand"
import "core:strings"
import "core:testing"

// Render a hand to its single-line string, for focused assertions.
hand_line_string :: proc(hand: Hand) -> string {
	builder := strings.builder_make()
	write_hand_line(&builder, hand)
	return strings.to_string(builder)
}

// One hand should render suits S H D C, ranks high-to-low, with a void shown as an empty field
// (here diamonds), giving the tell-tale double space.
@(test)
test_hand_line_sorts_and_marks_void :: proc(t: ^testing.T) {
	// Spades AKQJ, Hearts T9, Diamonds void, Clubs 8765432 — listed in scrambled order to prove
	// the renderer sorts rather than relying on input order.
	hand := Hand {
		make_card(.Clubs, .Five),
		make_card(.Spades, .Queen),
		make_card(.Clubs, .Two),
		make_card(.Hearts, .Nine),
		make_card(.Spades, .Ace),
		make_card(.Clubs, .Eight),
		make_card(.Spades, .Jack),
		make_card(.Clubs, .Seven),
		make_card(.Hearts, .Ten),
		make_card(.Spades, .King),
		make_card(.Clubs, .Six),
		make_card(.Clubs, .Four),
		make_card(.Clubs, .Three),
	}
	got := hand_line_string(hand)
	defer delete(got)
	testing.expect_value(t, got, "AKQJ T9  8765432")
}

// Dealing the ordered (unshuffled) deck gives each seat an entire suit, which makes a fully
// predictable line: North gets all clubs, East all diamonds, South all hearts, West all spades.
@(test)
test_deal_line_golden :: proc(t: ^testing.T) {
	board := deal_from_deck(full_deck())

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deal_line(&builder, board)

	// Each seat holds one whole suit, so voids surface as spaces:
	//   North (clubs)   -> 3 leading spaces then the 13 clubs
	//   East  (diamonds)-> 2 leading + 1 trailing space
	//   South (hearts)  -> 1 leading + 2 trailing spaces
	//   West  (spades)  -> the 13 spades then 3 trailing spaces
	expected := "   AKQJT98765432|  AKQJT98765432 | AKQJT98765432  |AKQJT98765432   "
	testing.expect_value(t, strings.to_string(builder), expected)
}

// The dispatcher must produce the same bytes as calling the line renderer directly.
@(test)
test_render_deal_dispatch_line :: proc(t: ^testing.T) {
	board := deal_from_deck(full_deck())

	direct := strings.builder_make()
	defer strings.builder_destroy(&direct)
	render_deal_line(&direct, board)

	dispatched := strings.builder_make()
	defer strings.builder_destroy(&dispatched)
	render_deal(&dispatched, board, .Line)

	testing.expect_value(t, strings.to_string(dispatched), strings.to_string(direct))
}

// The handviewer renderer emits BBO query params in N S E W order, each seat as
// `seat=s..h..d..c..`, with a fixed neutral auction/vul/dealer tail. On the ordered deck North holds
// all clubs, South all hearts, East all diamonds, West all spades, so each seat's params are exactly
// one populated suit.
@(test)
test_deal_handviewer_golden :: proc(t: ^testing.T) {
	board := deal_from_deck(full_deck())

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deal_handviewer(&builder, board)

	expected := "n=shdcAKQJT98765432&s=shAKQJT98765432dc&e=shdAKQJT98765432c&w=sAKQJT98765432hdc&a=_&v=-&d=n"
	testing.expect_value(t, strings.to_string(builder), expected)
}

// With randomize_table the seat params are unchanged but the vulnerability and dealer become one of
// the valid handviewer codes (drawn from the RNG), instead of the fixed `v=-&d=n`.
@(test)
test_handviewer_randomize_table :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 99)
	board := deal_from_deck(full_deck())

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deal_handviewer(&builder, board, true)
	text := strings.to_string(builder)

	// Seat params are identical to the deterministic rendering; only the table tail varies.
	seat_prefix := "n=shdcAKQJT98765432&s=shAKQJT98765432dc&e=shdAKQJT98765432c&w=sAKQJT98765432hdc&a=_&v="
	testing.expect(t, strings.has_prefix(text, seat_prefix), "seat params should be unchanged")

	tail := text[len(seat_prefix):] // "<vul>&d=<dealer>"
	parts := strings.split(tail, "&d=")
	defer delete(parts)
	testing.expect_value(t, len(parts), 2)
	testing.expect(t, strings.contains("-neb", parts[0]) && len(parts[0]) == 1, "vulnerability must be a valid code")
	testing.expect(t, strings.contains("nsew", parts[1]) && len(parts[1]) == 1, "dealer must be a valid code")
}

// The Html format brackets the deals with a page header/footer (once), and each deal is a handviewer
// iframe whose URL carries the same params the Handviewer format produces.
@(test)
test_html_page_wraps_deals :: proc(t: ^testing.T) {
	board := deal_from_deck(full_deck())

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_page_prologue(&builder, .Html)
	render_deal(&builder, board, .Html)
	render_page_epilogue(&builder, .Html)
	text := strings.to_string(builder)

	testing.expect(t, strings.has_prefix(text, "<!DOCTYPE html>"), "page should open with the doctype")
	testing.expect(
		t,
		strings.contains(text, "handviewer.html?n=shdcAKQJT98765432&s="),
		"iframe should carry handviewer params",
	)
	testing.expect(t, strings.contains(text, "</body>"), "page should close the body")
}

// The pretty renderer should emit one line per seat and show voids as '-'.
@(test)
test_deal_pretty_lines_and_voids :: proc(t: ^testing.T) {
	board := deal_from_deck(full_deck())

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	render_deal_pretty(&builder, board)
	text := strings.to_string(builder)

	lines := strings.split_lines(text)
	defer delete(lines)
	// Four seat lines plus a trailing empty element after the final '\n'.
	testing.expect_value(t, len(lines), SEAT_COUNT + 1)

	// North holds all clubs: spades/hearts/diamonds are voids shown as '-', clubs are the full run.
	testing.expect(t, strings.has_prefix(lines[0], "North "), "first line should label North")
	testing.expect(t, strings.contains(lines[0], "S:-"), "North spades should be a void")
	testing.expect(t, strings.contains(lines[0], "C:AKQJT98765432"), "North clubs should be the full suit")
}
