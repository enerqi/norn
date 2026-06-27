package norn

/*
	render.odin — turning a dealt board into text.

	This is the presentation layer: a pure transform from a `Deal` to its textual form. It does NOT
	send anything anywhere — choosing a destination (stdout, a file) is the driver's job in
	generate.odin. Different consumers want different shapes, so rendering is pluggable:
	`Output_Format` selects a renderer and `render_deal` dispatches to it. Adding a new format (e.g.
	HTML, or BBO handviewer query parameters) later means adding one enum value and one renderer —
	nothing else changes.

	All renderers write into a `strings.Builder` supplied by the caller. Keeping the string-building
	pure (board in, text in a builder, no I/O) is what makes these functions exhaustively testable
	against exact "golden" output.

	OUTPUT ORDERING
	---------------
	Seats are written N E S W (the order cards are dealt). Within a hand, suits are written
	spades-first (S H D C) and ranks high-to-low (A K Q J T 9 .. 2). Note this is the reverse of the
	ascending order the enums are declared in, so the orders below are spelled out explicitly.
*/

import "core:strings"

// Seats in the order they are written out.
SEAT_OUTPUT_ORDER :: [SEAT_COUNT]Seat{.North, .East, .South, .West}

// Suits in the order they are written within a hand (spades first).
SUIT_OUTPUT_ORDER :: [SUIT_COUNT]Suit{.Spades, .Hearts, .Diamonds, .Clubs}

// The available text renderings of a board.
Output_Format :: enum {
	// `Line` is the one-board-per-line format this program exists to produce — the same shape as
	// `deal`'s `-l` output, which downstream tooling already parses:
	//
	//	KQT874 K74  8743|A65 T32 AT96 J62|932 QJ65 Q42 AKQ|J A98 KJ8753 T95
	//
	// Per seat: the four suits S H D C, space-separated, ranks high-to-low; a void suit is the
	// empty string (which shows up as two adjacent spaces). Seats are joined with '|'.
	Line,
	// `Pretty` is a human-readable, labelled layout — one seat per line. Handy for eyeballing a
	// few deals; not meant for machine consumption.
	Pretty,
}

// Render `board` into `builder` using the chosen `format`.
render_deal :: proc(builder: ^strings.Builder, board: Deal, format: Output_Format) {
	switch format {
	case .Line:
		render_deal_line(builder, board)
	case .Pretty:
		render_deal_pretty(builder, board)
	}
}

// Write `board` as a single line: `north|east|south|west`, no trailing newline (the caller decides
// how to separate consecutive boards).
render_deal_line :: proc(builder: ^strings.Builder, board: Deal) {
	for seat, seat_index in SEAT_OUTPUT_ORDER {
		if seat_index > 0 {
			strings.write_byte(builder, '|')
		}
		write_hand_line(builder, board[seat])
	}
}

// Write one hand as `SSSS HHH DD CCCC`: the four suits in S H D C order separated by single
// spaces, each suit's ranks high-to-low, a void written as the empty string. There are always
// exactly three separating spaces, so voids surface as adjacent/leading/trailing spaces — which is
// how the downstream parser detects them.
write_hand_line :: proc(builder: ^strings.Builder, hand: Hand) {
	for suit, suit_index in SUIT_OUTPUT_ORDER {
		if suit_index > 0 {
			strings.write_byte(builder, ' ')
		}
		write_suit_ranks(builder, hand, suit)
	}
}

// Write the ranks of `hand` in `suit`, high-to-low, as packed rank characters (e.g. "KQT874").
// Returns how many cards were written so callers can detect a void (count == 0).
//
// We mark which ranks are present in a small lookup, then walk ranks from Ace down to Two, so the
// output is sorted descending without a separate sort step.
write_suit_ranks :: proc(builder: ^strings.Builder, hand: Hand, suit: Suit) -> (count: int) {
	present: [RANK_COUNT]bool
	for card in hand {
		if card_suit(card) == suit {
			present[u8(card_rank(card))] = true
		}
	}
	for rank := RANK_COUNT - 1; rank >= 0; rank -= 1 {
		if present[rank] {
			strings.write_rune(builder, rank_char(Rank(rank)))
			count += 1
		}
	}
	return
}

// Write `board` as four labelled lines, one per seat, e.g.:
//
//	North S:KQT874 H:K74 D:- C:8743
//
// A void suit is shown as '-' so every line has all four suits visible.
render_deal_pretty :: proc(builder: ^strings.Builder, board: Deal) {
	for seat in SEAT_OUTPUT_ORDER {
		name := seat_name(seat)
		strings.write_string(builder, name)
		// Pad the (4- or 5-letter) seat name to a fixed width so the suits line up in a column.
		for _ in len(name) ..< 6 {
			strings.write_byte(builder, ' ')
		}
		for suit in SUIT_OUTPUT_ORDER {
			strings.write_rune(builder, suit_letter(suit))
			strings.write_byte(builder, ':')
			count := write_suit_ranks(builder, board[seat], suit)
			if count == 0 {
				strings.write_byte(builder, '-') // void
			}
			strings.write_byte(builder, ' ')
		}
		strings.write_byte(builder, '\n')
	}
}

// The full name of a seat, used by the pretty renderer.
seat_name :: proc "contextless" (seat: Seat) -> string {
	switch seat {
	case .North:
		return "North"
	case .East:
		return "East"
	case .South:
		return "South"
	case .West:
		return "West"
	}
	return "?" // unreachable: the switch above is exhaustive over Seat
}
