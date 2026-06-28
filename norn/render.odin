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

import "core:math/rand"
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
	// `Handviewer` is the BBO (Bridge Base Online) handviewer query string for one deal:
	//
	//	n=sKQT874hK74d8743c&s=...&e=...&w=...&a=_&v=-&d=n
	//
	// One `seat=s<spades>h<hearts>d<diamonds>c<clubs>` field per seat (N S E W order, BBO's), joined
	// with '&', then a neutral empty auction / no-vulnerability / North-dealer tail. Append it to
	// `https://www.bridgebase.com/tools/handviewer.html?` to view the deal. See
	// https://www.bridgebase.com/tools/hvdoc.html.
	Handviewer,
	// `Html` wraps each deal as a handviewer `<iframe>` inside a standalone HTML page (a page header
	// is emitted once before the deals and a footer once after — see the generation driver). This is
	// the Odin equivalent of the `run-deal.py --html-output-path` export.
	Html,
	// `Pbn` is the Portable Bridge Notation deal tag, one board per line:
	//
	//	[Deal "N:T84.QJ.KQ976.A52 Q9.AK87.J8.KQ964 KJ32.T96.AT.J873 A765.5432.543.T"]
	//
	// One hand per seat in clockwise order from the prefix seat (N E S W), each hand's four suits in
	// S.H.D.C order separated by '.', ranks high-to-low, a void written as the empty string (adjacent
	// dots). This is the `[Deal]` tag every PBN importer reads; the surrounding per-board tags of a
	// full PBN export (Event, Board, Dealer, …) are intentionally omitted — add them only if a strict
	// importer needs them. Matches deal's `pbn` formatter for the deal field itself.
	Pbn,
	// `Numeric` is deal's compact `numeric` format: a 52-character digit string per board, one digit
	// per card giving its owner seat (North 0, East 1, South 2, West 3). The cards are walked in a
	// fixed order — suits S H D C, and within each suit ranks high-to-low A K Q J T 9 .. 2 — so the
	// position encodes the card and the digit encodes who holds it. No separators; reversible back to
	// a full deal. (The seat digits coincide with norn's `Seat` backing values.)
	Numeric,
}

// Render `board` into `builder` using the chosen `format`. `randomize_table` only affects the
// handviewer-based formats: when true the vulnerability and dealer are drawn from
// `context.random_generator`; when false they are fixed (`v=-`, `d=n`) so output stays deterministic.
render_deal :: proc(builder: ^strings.Builder, board: Deal, format: Output_Format, randomize_table := false) {
	switch format {
	case .Line:
		render_deal_line(builder, board)
	case .Pretty:
		render_deal_pretty(builder, board)
	case .Handviewer:
		render_deal_handviewer(builder, board, randomize_table)
	case .Html:
		render_deal_html_iframe(builder, board, randomize_table)
	case .Pbn:
		render_deal_pbn(builder, board)
	case .Numeric:
		render_deal_numeric(builder, board)
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

// Write `board` as a PBN `[Deal]` tag (see the `Pbn` doc on `Output_Format`), no trailing newline.
// The prefix seat is North, so the four hands follow in clockwise N E S W order — exactly
// `SEAT_OUTPUT_ORDER`.
render_deal_pbn :: proc(builder: ^strings.Builder, board: Deal) {
	strings.write_string(builder, `[Deal "N:`)
	for seat, seat_index in SEAT_OUTPUT_ORDER {
		if seat_index > 0 {
			strings.write_byte(builder, ' ')
		}
		write_hand_pbn(builder, board[seat])
	}
	strings.write_string(builder, `"]`)
}

// Write one hand as `S.H.D.C`: the four suits in S H D C order separated by '.', each suit's ranks
// high-to-low, a void written as the empty string (so a void surfaces as adjacent/leading/trailing
// dots, the PBN convention).
write_hand_pbn :: proc(builder: ^strings.Builder, hand: Hand) {
	for suit, suit_index in SUIT_OUTPUT_ORDER {
		if suit_index > 0 {
			strings.write_byte(builder, '.')
		}
		write_suit_ranks(builder, hand, suit)
	}
}

// Write `board` as deal's compact `numeric` string (see the `Numeric` doc on `Output_Format`), no
// trailing newline: 52 owner-seat digits, the cards walked in S H D C order and, within each suit,
// ranks high-to-low.
render_deal_numeric :: proc(builder: ^strings.Builder, board: Deal) {
	// Owner seat of each card, indexed by the card's value, so the walk below is a plain lookup.
	owner: [DECK_SIZE]Seat
	for seat in Seat {
		for card in board[seat] {
			owner[int(card)] = seat
		}
	}
	for suit in SUIT_OUTPUT_ORDER {
		for rank := RANK_COUNT - 1; rank >= 0; rank -= 1 {
			card := make_card(suit, Rank(rank))
			strings.write_byte(builder, '0' + u8(owner[int(card)]))
		}
	}
}

// Seats in BBO handviewer parameter order (n, s, e, w) — note this differs from the N E S W output
// order used by the line/pretty renderers.
HANDVIEWER_SEAT_ORDER :: [SEAT_COUNT]Seat{.North, .South, .East, .West}

// Handviewer vulnerability codes (none / NS / EW / both) and dealer codes (N S E W), used when
// `randomize_table` picks a random table; index 0 of each is the deterministic default.
@(private = "file")
HANDVIEWER_VULNERABILITIES := [4]string{"-", "n", "e", "b"}
@(private = "file")
HANDVIEWER_DEALERS := [4]string{"n", "s", "e", "w"}

// Write `board` as a BBO handviewer query string (see the `Handviewer` doc on `Output_Format`):
// `n=s..h..d..c..&s=...&e=...&w=...&a=_&v=..&d=..`, no trailing newline. With `randomize_table` the
// vulnerability and dealer are drawn from `context.random_generator` (matching the Python tool's
// practice-variety randomisation); otherwise they are fixed to `v=-`, `d=n` for deterministic output.
render_deal_handviewer :: proc(builder: ^strings.Builder, board: Deal, randomize_table := false) {
	for seat in HANDVIEWER_SEAT_ORDER {
		strings.write_rune(builder, handviewer_seat_letter(seat))
		strings.write_byte(builder, '=')
		for suit in SUIT_OUTPUT_ORDER {
			strings.write_rune(builder, handviewer_suit_letter(suit))
			write_suit_ranks(builder, board[seat], suit)
		}
		strings.write_byte(builder, '&')
	}

	vulnerability := HANDVIEWER_VULNERABILITIES[0]
	dealer := HANDVIEWER_DEALERS[0]
	if randomize_table {
		vulnerability = HANDVIEWER_VULNERABILITIES[rand.int_max(len(HANDVIEWER_VULNERABILITIES))]
		dealer = HANDVIEWER_DEALERS[rand.int_max(len(HANDVIEWER_DEALERS))]
	}
	// Empty auction, then the (fixed or random) vulnerability and dealer.
	strings.write_string(builder, "a=_&v=")
	strings.write_string(builder, vulnerability)
	strings.write_string(builder, "&d=")
	strings.write_string(builder, dealer)
}

// The HTML fragment that opens one handviewer iframe, up to (and including) the `?` of the URL.
@(private = "file")
HTML_IFRAME_PREFIX :: `    <div>
        <iframe src="https://www.bridgebase.com/tools/handviewer.html?`

// The HTML fragment that closes the iframe opened by HTML_IFRAME_PREFIX.
@(private = "file")
HTML_IFRAME_SUFFIX :: `"
        height="900px" width="900px"
        title="Random hand"
        id="hand_frame"></iframe>
    </div>`

// Write `board` as a handviewer `<iframe>` div (one deal of an `Html`-format page). The page header
// and footer that surround a run of these are emitted by the generation driver, not here.
// `randomize_table` is forwarded to the handviewer params in the iframe URL.
render_deal_html_iframe :: proc(builder: ^strings.Builder, board: Deal, randomize_table := false) {
	strings.write_string(builder, HTML_IFRAME_PREFIX)
	render_deal_handviewer(builder, board, randomize_table)
	strings.write_string(builder, HTML_IFRAME_SUFFIX)
}

// The header emitted once before the deals of an `Html`-format run (everything up to the deal divs).
@(private = "file")
HTML_PAGE_HEADER :: `<!DOCTYPE html>
<head>
    <title>Practice Deals</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet">
    <style>
        body { font-family: 'Open Sans'; }
        .content { margin: auto; max-width: 900px; }
        iframe { margin-top: 4rem; margin-bottom: 4rem; }
    </style>
</head>
<body class="content">
`

// The footer emitted once after the deals of an `Html`-format run.
@(private = "file")
HTML_PAGE_FOOTER :: `</body>
`

// Write the once-per-run prologue for `format`. Only `Html` has one (the page header); every other
// format opens with nothing.
render_page_prologue :: proc(builder: ^strings.Builder, format: Output_Format) {
	if format == .Html {
		strings.write_string(builder, HTML_PAGE_HEADER)
	}
}

// Write the once-per-run epilogue for `format`. Mirror of `render_page_prologue`.
render_page_epilogue :: proc(builder: ^strings.Builder, format: Output_Format) {
	if format == .Html {
		strings.write_string(builder, HTML_PAGE_FOOTER)
	}
}

// The BBO handviewer seat letter (lowercase n/e/s/w).
@(private = "file")
handviewer_seat_letter :: proc "contextless" (seat: Seat) -> rune {
	switch seat {
	case .North:
		return 'n'
	case .East:
		return 'e'
	case .South:
		return 's'
	case .West:
		return 'w'
	}
	return '?' // unreachable: the switch above is exhaustive over Seat
}

// The BBO handviewer suit letter (lowercase s/h/d/c).
@(private = "file")
handviewer_suit_letter :: proc "contextless" (suit: Suit) -> rune {
	switch suit {
	case .Spades:
		return 's'
	case .Hearts:
		return 'h'
	case .Diamonds:
		return 'd'
	case .Clubs:
		return 'c'
	}
	return '?' // unreachable: the switch above is exhaustive over Suit
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
