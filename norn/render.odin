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

import "core:fmt"
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
	// `Html_Handviewer` wraps each deal as a BBO handviewer `<iframe>` inside a standalone HTML page (a
	// page header is emitted once before the deals and a footer once after — see the generation
	// driver). This is the Odin equivalent of the `run-deal.py --html-output-path` export. Every board
	// is a live handviewer that loads from bridgebase.com; for an offline, self-rendered page see
	// `Html_Cards`.
	Html_Handviewer,
	// `Html_Cards` is a self-contained, offline HTML page: every deal is drawn as a text compass
	// diagram (four hands, suit glyph + ranks) inside a client-side carousel — no BBO iframe, no remote
	// load. The page header (emitted once) carries the carousel shell, CSS, and a static `<script>`
	// that groups each rendered board (+ its optional par caption) into a slide and wires the nav
	// (prev/next, ←/→ keys, jump box, deal counter), a seat toggle (show all / just one seat across
	// every board), and a par toggle. Per deal this renderer emits only the compass `<div>`; the par
	// caption is appended by the consumer's annotator as a following `.par` sibling (the script pairs
	// them). Unlike `Html` it never contacts the network, so nav is instant and it works offline.
	Html_Cards,
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
	case .Html_Handviewer:
		render_deal_html_iframe(builder, board, randomize_table)
	case .Html_Cards:
		render_deal_html_cards(builder, board, randomize_table)
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

// Human-readable vulnerability / dealer labels for the card diagram's centre table. Indexed in
// parallel with HANDVIEWER_VULNERABILITIES / HANDVIEWER_DEALERS, so a random draw shares the same
// semantics as the handviewer formats; index 0 of each is the deterministic default.
@(private = "file")
HTML_CARDS_VULNERABILITIES := [4]string{"None", "NS", "EW", "Both"}
@(private = "file")
HTML_CARDS_DEALERS := [4]string{"N", "S", "E", "W"}

// Write `board` as a text compass diagram (one deal of an `Html_Cards` page): North on top, then a
// middle row of West / centre table / East, then South. Each hand lists its four suits (S H D C) as
// a suit glyph plus ranks, a void shown as an em-dash. The centre table shows dealer and
// vulnerability. `randomize_table` draws those from `context.random_generator` (matching the
// handviewer formats); otherwise they are the fixed defaults. No page chrome here — the carousel
// shell and script are emitted once by the page prologue/epilogue.
render_deal_html_cards :: proc(builder: ^strings.Builder, board: Deal, randomize_table := false) {
	vul_index := 0
	dealer_index := 0
	if randomize_table {
		vul_index = rand.int_max(len(HTML_CARDS_VULNERABILITIES))
		dealer_index = rand.int_max(len(HTML_CARDS_DEALERS))
	}
	// Vulnerability by partnership: index 1 = NS, 2 = EW, 3 = Both (0 = None). The seat labels are
	// coloured from this (see write_compass_seat), and the centre table shows the summary word.
	ns_vulnerable := vul_index == 1 || vul_index == 3
	ew_vulnerable := vul_index == 2 || vul_index == 3
	dealer := HTML_CARDS_DEALERS[dealer_index] // "N" / "S" / "E" / "W"

	// Per-seat summary (hcp + suit-length pattern) from the same index the predicates use.
	ds := summarize_deal(board)

	strings.write_string(builder, `<div class="compass">`)

	// Partnership high-card-point summary, pinned top-right (see the .stats CSS).
	n_hcp, s_hcp := hcp(ds[.North]), hcp(ds[.South])
	e_hcp, w_hcp := hcp(ds[.East]), hcp(ds[.West])
	strings.write_string(builder, `<div class="stats">`)
	fmt.sbprintf(builder, `<div>NS: %d + %d = %d HCP</div>`, n_hcp, s_hcp, n_hcp + s_hcp)
	fmt.sbprintf(builder, `<div>EW: %d + %d = %d HCP</div>`, e_hcp, w_hcp, e_hcp + w_hcp)
	// Per-suit E–W split (how N/S's opponents' cards in each suit break), largest-first, with the
	// a-priori probability of that break. Hidden on phones (see the media query).
	strings.write_string(builder, `<div class="splits">`)
	for suit in SUIT_OUTPUT_ORDER {
		write_suit_split(builder, ds, suit)
	}
	strings.write_string(builder, `</div>`)
	strings.write_string(builder, `</div>`)

	write_compass_seat(builder, board, ds, .North, "N", "n", ns_vulnerable, dealer == "N")
	strings.write_string(builder, `<div class="mid">`)
	write_compass_seat(builder, board, ds, .West, "W", "w", ew_vulnerable, dealer == "W")
	strings.write_string(builder, `<div class="table">Vul `)
	strings.write_string(builder, HTML_CARDS_VULNERABILITIES[vul_index])
	strings.write_string(builder, `</div>`)
	write_compass_seat(builder, board, ds, .East, "E", "e", ew_vulnerable, dealer == "E")
	strings.write_string(builder, `</div>`) // .mid
	write_compass_seat(builder, board, ds, .South, "S", "s", ns_vulnerable, dealer == "S")
	strings.write_string(builder, `</div>`) // .compass
}

// Write one seat of a card compass: a `.seat seat-<class>` div holding a label then the four suits,
// each a `.suit <letter>` line of glyph + ranks (void shown as an em-dash). The class letter drives
// the seat-toggle CSS (hide every seat but one) and the per-suit colouring. `vulnerable` adds a `vul`
// / `nonvul` class so the label pill is coloured by vulnerability, and `dealer` adds `is-dealer`
// (a ring plus a "Dealer" tag) so the dealer stands out.
@(private = "file")
write_compass_seat :: proc(
	builder: ^strings.Builder,
	board: Deal,
	ds: Deal_Summary,
	seat: Seat,
	label: string,
	class: string,
	vulnerable: bool,
	dealer: bool,
) {
	strings.write_string(builder, `<div class="seat seat-`)
	strings.write_string(builder, class)
	strings.write_string(builder, " vul" if vulnerable else " nonvul")
	if dealer {
		strings.write_string(builder, " is-dealer")
	}
	strings.write_string(builder, `"><span class="lbl">`)
	strings.write_string(builder, label)
	strings.write_string(builder, `</span>`)
	if dealer {
		strings.write_string(builder, `<span class="dtag">Dealer</span>`)
	}
	for suit in SUIT_OUTPUT_ORDER {
		strings.write_string(builder, `<span class="suit `)
		strings.write_rune(builder, handviewer_suit_letter(suit))
		strings.write_string(builder, `"><span class="sym">`)
		strings.write_string(builder, suit_glyph(suit))
		strings.write_string(builder, `</span>`)
		count := write_suit_ranks(builder, board[seat], suit)
		if count == 0 {
			strings.write_string(builder, "&mdash;") // void
		}
		strings.write_string(builder, `</span>`)
	}

	// This hand's own high-card points, above the shape line.
	strings.write_string(builder, `<div class="hcp">`)
	fmt.sbprintf(builder, "%d HCP", hcp(ds[seat]))
	strings.write_string(builder, `</div>`)

	// Placeholder for the optimal point count (honour-combination valuation) — not computed yet.
	strings.write_string(builder, `<div class="opc">OPC: &mdash;</div>`)

	// Shape line: the suit-agnostic pattern (lengths sorted high-to-low) and how common it is.
	p := pattern(ds[seat])
	strings.write_string(builder, `<div class="shape">`)
	fmt.sbprintf(builder, "%d-%d-%d-%d", p[0], p[1], p[2], p[3])
	strings.write_string(builder, ` <span class="prob">`)
	strings.write_string(builder, shape_probability(p))
	strings.write_string(builder, `</span></div>`)

	strings.write_string(builder, `</div>`)
}

// Write one suit's E–W split as a `.split` row: the coloured suit glyph, the largest-first break of
// the cards East and West hold in that suit (e.g. "4-3"), and the a-priori probability of that break.
// A suit where E–W are both void shows "void" with no odds.
@(private = "file")
write_suit_split :: proc(builder: ^strings.Builder, ds: Deal_Summary, suit: Suit) {
	e := suit_length(ds[.East], suit)
	w := suit_length(ds[.West], suit)
	outstanding := e + w
	hi, lo := max(e, w), min(e, w)

	strings.write_string(builder, `<div class="split"><span class="ssym `)
	strings.write_rune(builder, handviewer_suit_letter(suit))
	strings.write_string(builder, `">`)
	strings.write_string(builder, suit_glyph(suit))
	strings.write_string(builder, `</span>`)
	if outstanding == 0 {
		strings.write_string(builder, `<span>void</span>`)
	} else {
		fmt.sbprintf(builder, `<span>%d-%d</span><span class="pct">`, hi, lo)
		write_split_percent(builder, suit_split_percent(outstanding, hi))
		strings.write_string(builder, `</span>`)
	}
	strings.write_string(builder, `</div>`)
}

// The order-agnostic probability (percent) that `outstanding` cards split hi-lo between two unseen
// 13-card hands — the classic bridge "suit break" odds. Uses the hypergeometric distribution over the
// 26 cards of the two hands and combines the two directions (e.g. 4-3 counts both 4-3 and 3-4), so it
// matches published split tables. Every outstanding count 0..13 is handled, so no lookup table is kept.
@(private = "file")
suit_split_percent :: proc(outstanding, hi: int) -> f64 {
	if outstanding <= 0 {
		return 0
	}
	lo := outstanding - hi
	// P(a chosen hand holds exactly `hi` of the outstanding cards); the other hand then holds `lo`.
	p := binom_f64(outstanding, hi) * binom_f64(26 - outstanding, 13 - hi) / binom_f64(26, 13)
	if hi != lo {
		p *= 2 // the two hands are symmetric, so an uneven split can fall either way round
	}
	return p * 100
}

// Format a split probability: two decimals, or "<0.01%" for the very rare breaks.
@(private = "file")
write_split_percent :: proc(builder: ^strings.Builder, pct: f64) {
	if pct >= 0.01 {
		fmt.sbprintf(builder, "%.2f%%", pct)
	} else {
		strings.write_string(builder, "&lt;0.01%")
	}
}

// C(n, k) as an f64, computed multiplicatively to stay exact for the small n (<= 26) used here without
// overflowing an integer factorial.
@(private = "file")
binom_f64 :: proc(n, k: int) -> f64 {
	if k < 0 || k > n {
		return 0
	}
	kk := min(k, n - k)
	r: f64 = 1
	for i in 0 ..< kk {
		r = r * f64(n - i) / f64(i + 1)
	}
	return r
}

// How common a hand pattern is (suit lengths sorted high-to-low), as a display string: the
// probability to two decimal places, or a "1 in N" odds string when it is rarer than 0.1%. The
// figures are the exact 13-card dealing probabilities for each of the 39 patterns; an unknown pattern
// (should never happen — every hand has one of these) returns "".
@(private = "file")
shape_probability :: proc(p: [SUIT_COUNT]int) -> string {
	switch fmt.tprintf("%d-%d-%d-%d", p[0], p[1], p[2], p[3]) {
	case "4-3-3-3":
		return "10.54%"
	case "4-4-3-2":
		return "21.55%"
	case "4-4-4-1":
		return "2.99%"
	case "5-3-3-2":
		return "15.52%"
	case "5-4-2-2":
		return "10.58%"
	case "5-4-3-1":
		return "12.93%"
	case "5-4-4-0":
		return "1.24%"
	case "5-5-2-1":
		return "3.17%"
	case "5-5-3-0":
		return "0.90%"
	case "6-3-2-2":
		return "5.64%"
	case "6-3-3-1":
		return "3.45%"
	case "6-4-2-1":
		return "4.70%"
	case "6-4-3-0":
		return "1.33%"
	case "6-5-1-1":
		return "0.71%"
	case "6-5-2-0":
		return "0.65%"
	case "6-6-1-0":
		return "1 in 1,382"
	case "7-2-2-2":
		return "0.51%"
	case "7-3-2-1":
		return "1.88%"
	case "7-3-3-0":
		return "0.27%"
	case "7-4-1-1":
		return "0.39%"
	case "7-4-2-0":
		return "0.36%"
	case "7-5-1-0":
		return "0.11%"
	case "7-6-0-0":
		return "1 in 17,971"
	case "8-2-2-1":
		return "0.19%"
	case "8-3-1-1":
		return "0.12%"
	case "8-3-2-0":
		return "0.11%"
	case "8-4-1-0":
		return "1 in 2,212"
	case "8-5-0-0":
		return "1 in 31,948"
	case "9-2-1-1":
		return "1 in 5,615"
	case "9-2-2-0":
		return "1 in 12,165"
	case "9-3-1-0":
		return "1 in 9,953"
	case "9-4-0-0":
		return "1 in 103,512"
	case "10-1-1-1":
		return "1 in 252,654"
	case "10-2-1-0":
		return "1 in 91,236"
	case "10-3-0-0":
		return "1 in 646,948"
	case "11-1-1-0":
		return "1 in 4,014,398"
	case "11-2-0-0":
		return "1 in 8,697,863"
	case "12-1-0-0":
		return "1 in 313,123,057"
	case "13-0-0-0":
		return "1 in 158,753,389,900"
	}
	return ""
}

// The Unicode card-suit glyph, used by the card diagram (hearts/diamonds are coloured red via CSS).
@(private = "file")
suit_glyph :: proc "contextless" (suit: Suit) -> string {
	switch suit {
	case .Spades:
		return "♠" // ♠
	case .Hearts:
		return "♥" // ♥
	case .Diamonds:
		return "♦" // ♦
	case .Clubs:
		return "♣" // ♣
	}
	return "?" // unreachable: the switch above is exhaustive over Suit
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

// The header for an `Html_Cards` run: page chrome, the carousel CSS, the toolbar, and the open
// viewport/track that the rendered compass diagrams are written into. The matching footer closes the
// track and carries the script. Kept as a raw literal (it contains no backticks) so it needs no
// escaping. The script deliberately uses plain string concatenation, not template literals, to keep
// the whole thing backtick-free.
@(private = "file")
HTML_CARDS_PAGE_HEADER :: `<!DOCTYPE html>
<head>
    <title>Practice Deals</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet">
    <style>
        :root { --ink:#222; --red:#c00; --line:#ccc; --sel:#2b6cb0; --felt:#3f7d5c; --felt-dark:#2f5f46; }
        * { box-sizing: border-box; }
        body { font-family: 'Open Sans', sans-serif; color: var(--ink); margin: 0; }
        /* Compact control pill, pinned top-left — fit-content so its background never spans the width
           and blocks the centred card on wide screens. */
        .toolbar {
            position: sticky; top: 0; z-index: 10; width: fit-content;
            background: #fff; border: 1px solid var(--line); border-radius: 0 0 10px 0;
            box-shadow: 0 2px 8px rgba(0,0,0,0.15);
            display: flex; flex-wrap: wrap; gap: 0.3rem 0.6rem; align-items: center;
            padding: 0.35rem 0.6rem;
        }
        .toolbar button { font: inherit; font-size: 0.9rem; padding: 0.15rem 0.45rem; cursor: pointer; border: 1px solid var(--line); background: #f7f7f7; border-radius: 4px; }
        .toolbar button:hover { background: #ececec; }
        .toolbar .sel { background: var(--sel); color: #fff; border-color: var(--sel); }
        .toolbar .off { opacity: 0.5; }
        .toolbar .group { display: flex; gap: 0.2rem; align-items: center; }
        .toolbar .counter { font-variant-numeric: tabular-nums; font-size: 0.9rem; }
        .toolbar input { font: inherit; font-size: 0.9rem; width: 3rem; padding: 0.15rem 0.25rem; }
        .toolbar .lbl-txt { color: #666; font-size: 0.78rem; }
        .viewport { overflow: hidden; width: 100%; padding: 0.75rem 0; }
        .track { display: flex; align-items: center; gap: 40px; transition: transform 0.35s ease; will-change: transform; }
        /* Hug the (grouped) board content and cap at the viewport width, so the slide scales with the
           mid-row gap above — wide on big monitors, compact at 1080p — rather than a fixed pixel width. */
        .slide {
            flex: 0 0 auto; width: fit-content; max-width: 96vw;
            opacity: 0.4; transform: scale(0.9); transition: opacity 0.35s ease, transform 0.35s ease;
        }
        .slide.active { opacity: 1; transform: scale(1); }
        /* The board is a green "tablecloth"; each hand sits on it as its own light card panel. */
        .compass {
            position: relative;
            border: 1px solid var(--felt-dark); border-radius: 12px; background: var(--felt);
            padding: clamp(0.6rem, 1.5vh, 1.5rem) clamp(0.5rem, 3vw, 2rem);
            display: flex; flex-direction: column; gap: clamp(0.35rem, 1.1vh, 1.2rem);
        }
        .slide.active .compass { box-shadow: 0 0 0 3px var(--sel), 0 8px 24px rgba(0,0,0,0.25); }
        /* Partnership HCP summary, pinned to the felt's top-right corner. */
        .stats {
            position: absolute; top: 1.1rem; right: 1.4rem; text-align: right;
            background: rgba(255,255,255,0.92); color: #333; padding: 0.5rem 0.7rem; border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.2);
            font-family: 'Consolas', 'Courier New', monospace; font-size: 1.05rem; line-height: 1.5;
        }
        .stats .splits { margin-top: 0.35rem; border-top: 1px solid #ddd; padding-top: 0.3rem; }
        .stats .split { display: flex; justify-content: flex-end; align-items: baseline; gap: 0.45rem; }
        .stats .split .pct { color: #888; min-width: 4.3em; text-align: right; }
        .stats .ssym { font-size: 1.15em; }
        .ssym.s { color: Black; } .ssym.h { color: Red; } .ssym.d { color: Orange; } .ssym.c { color: MediumSeaGreen; }
        /* Per-hand shape pattern + how common it is, under each hand's cards. */
        .hcp { margin-top: 0.25rem; font-family: 'Open Sans', sans-serif; font-size: 0.5em; font-weight: 600; color: #555; }
        .opc { margin-top: 0.1rem; font-family: 'Open Sans', sans-serif; font-size: 0.42em; color: #777; }
        .shape {
            margin-top: 0.1rem; font-family: 'Open Sans', sans-serif; font-size: 0.4em;
            font-weight: 300; color: #9a9a9a; opacity: 0.75;
        }
        .shape .prob { color: #b5b5b5; }
        /* West / table / East grouped and centred, with a gap that grows on wide monitors and shrinks
           at lower resolutions so the hands compress toward one another instead of flinging to the edges. */
        .compass .mid { display: flex; justify-content: center; align-items: center; gap: clamp(0.5rem, 7vw, 6rem); }
        /* Card text sizes off the SMALLER of viewport height/width, so it fits both axes — key for
           phones where width is the tight one (landscape) or height is (portrait). */
        .seat {
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: clamp(1rem, min(2.4vh, 4.3vw), 2.2rem);
            line-height: 1.28; min-width: clamp(5rem, 20vw, 11rem);
            background: #fff; border-radius: 10px; padding: 0.5rem 1rem 0.45rem; box-shadow: 0 2px 6px rgba(0,0,0,0.25);
        }
        /* North/South: centre the hand as a block but keep its suit lines left-aligned to the suit
           symbol, so the symbols form a column exactly like East/West (which are already left-aligned). */
        .compass > .seat { width: fit-content; margin: 0 auto; }
        /* The dealer's pill carries a ring, so give that seat extra top room to clear the card border. */
        .seat.is-dealer { padding-top: 0.85rem; }
        /* Seat label: a big pill coloured by vulnerability (red = vulnerable, green = not). */
        .seat .lbl {
            display: inline-block; font-weight: 700; font-size: 1.7em; line-height: 1;
            padding: 0.02em 0.28em; border-radius: 14px; color: #fff; margin-bottom: 0.25rem;
        }
        .seat.vul .lbl { background: var(--red); }
        .seat.nonvul .lbl { background: ForestGreen; }
        /* Dealer: ring around the pill plus a tag underneath. */
        .seat.is-dealer .lbl { box-shadow: 0 0 0 3px #fff, 0 0 0 6px var(--sel); }
        .dtag {
            display: block; margin: 0.35rem 0 0.4rem; font-family: 'Open Sans', sans-serif;
            font-size: 0.38em; font-weight: 700; letter-spacing: 0.12em; text-transform: uppercase; color: var(--sel);
        }
        /* Four-colour suits, matching the bidding-system stylesheet (bml.css). */
        .suit { display: block; white-space: nowrap; }
        .suit.s { color: Black; }
        .suit.h { color: Red; }
        .suit.d { color: Orange; }
        .suit.c { color: MediumSeaGreen; }
        .suit .sym { display: inline-block; width: 1.15em; }
        .table {
            border: 1px solid rgba(255,255,255,0.35); border-radius: 8px; padding: 0.7rem 1.1rem; text-align: center;
            font-size: 1.3rem; color: #fff; background: rgba(255,255,255,0.12); white-space: nowrap;
        }
        .par { margin-top: clamp(0.4rem, 1.1vh, 1rem); text-align: center; color: #555; font-size: clamp(1rem, 1.8vh, 1.3rem); }
        /* Seat toggle: keep just one seat visible across every board (layout preserved via visibility). */
        /* Single-seat view: the other three seats collapse to just their position pill (and Dealer tag),
           so the compass orientation, vulnerability, and dealer stay visible — only their cards hide. */
        .track.only-n .seat:not(.seat-n), .track.only-e .seat:not(.seat-e),
        .track.only-s .seat:not(.seat-s), .track.only-w .seat:not(.seat-w) {
            background: transparent; box-shadow: none; min-width: 0; padding: 0.2rem;
        }
        .track.only-n .seat:not(.seat-n) :is(.suit, .hcp, .opc, .shape),
        .track.only-e .seat:not(.seat-e) :is(.suit, .hcp, .opc, .shape),
        .track.only-s .seat:not(.seat-s) :is(.suit, .hcp, .opc, .shape),
        .track.only-w .seat:not(.seat-w) :is(.suit, .hcp, .opc, .shape) { display: none; }
        /* The Dealer tag sits on the green felt for these markers (transparent card), so make it white. */
        .track.only-n .seat:not(.seat-n) .dtag, .track.only-e .seat:not(.seat-e) .dtag,
        .track.only-s .seat:not(.seat-s) .dtag, .track.only-w .seat:not(.seat-w) .dtag { color: #fff; }
        /* The chosen seat grows by REAL layout (font-size, everything inside is em-relative), so the
           green felt reflows to contain it — a transform would leave the card spilling off a small felt. */
        .seat { transition: font-size 0.25s ease; }
        .track.only-n .seat-n, .track.only-e .seat-e,
        .track.only-s .seat-s, .track.only-w .seat-w { font-size: clamp(1.6rem, min(4vh, 6.5vw), 3.4rem); }
        /* The partnership HCP summary is meaningless with only one hand shown, so hide it then. */
        .track.only-n .stats, .track.only-e .stats,
        .track.only-s .stats, .track.only-w .stats { display: none; }
        .track.hide-par .par { display: none; }

        /* Phones: strip the secondary lines (OPC/shape), pull the hands tight together, and shrink the
           HCP badge + centre table so a whole board fits a small screen in either orientation. */
        @media (max-width: 640px) {
            .opc, .shape { display: none; }
            .seat { min-width: 0; padding: 0.4rem 0.6rem 0.35rem; }
            .seat.is-dealer { padding-top: 0.7rem; }
            .compass { gap: clamp(0.25rem, 0.8vh, 0.7rem); padding: clamp(0.4rem, 1vh, 0.9rem) clamp(0.4rem, 2vw, 1rem); }
            .compass .mid { gap: clamp(0.3rem, 3vw, 1.2rem); }
            .hcp { font-size: 0.95rem; margin-top: 0.15rem; }
            /* Too narrow for a top-right overlay without covering North — flow it above the board as a
               centred header line instead. */
            .stats {
                position: static; display: flex; justify-content: center; gap: 1rem;
                margin: 0 0 0.2rem; padding: 0.15rem 0.4rem; font-size: 0.82rem; line-height: 1.3;
            }
            .stats .splits { display: none; } /* HCP totals only on phones */
            .table { font-size: 1rem; padding: 0.45rem 0.7rem; }
            .dtag { font-size: 0.7rem; margin: 0.25rem 0 0.3rem; }
            .track { gap: 20px; }
        }
    </style>
</head>
<body>
    <div class="toolbar">
        <div class="group">
            <button id="nc-prev" title="Previous (Left arrow / scroll)">&#9664;</button>
            <span class="counter"><b id="nc-idx">1</b>/<span id="nc-total">0</span></span>
            <button id="nc-next" title="Next (Right arrow / scroll)">&#9654;</button>
        </div>
        <div class="group"><span class="lbl-txt">jump</span><input id="nc-jump" type="number" min="1" value="1"></div>
        <div class="group">
            <span class="lbl-txt">seats</span>
            <button data-seat="" class="sel">All</button>
            <button data-seat="n">N</button>
            <button data-seat="e">E</button>
            <button data-seat="s">S</button>
            <button data-seat="w">W</button>
        </div>
        <button id="nc-par-toggle">Par</button>
    </div>
    <div class="viewport">
        <div class="track" id="nc-track">
`

// The footer for an `Html_Cards` run: closes the track/viewport, then the script that turns the
// flat sequence of compass (and par) elements into slides and drives the carousel.
@(private = "file")
HTML_CARDS_PAGE_FOOTER :: `        </div>
    </div>
    <script>
    (function () {
        var track = document.getElementById('nc-track');
        // Each accepted deal wrote a .compass and (with --dd) a following .par sibling. Group each
        // compass with its par into one .slide, so the carousel moves them together.
        var comps = Array.prototype.slice.call(track.querySelectorAll(':scope > .compass'));
        var slides = comps.map(function (c) {
            var par = c.nextElementSibling;
            var slide = document.createElement('div');
            slide.className = 'slide';
            track.insertBefore(slide, c);
            slide.appendChild(c);
            if (par && par.classList.contains('par')) slide.appendChild(par);
            return slide;
        });

        var idx = 0;
        var total = slides.length;
        document.getElementById('nc-total').textContent = total;
        var jump = document.getElementById('nc-jump');
        jump.max = Math.max(total, 1);

        function show(i) {
            idx = Math.max(0, Math.min(total - 1, i));
            for (var j = 0; j < slides.length; j++) slides[j].classList.toggle('active', j === idx);
            var s = slides[idx];
            if (s) {
                // Centre the active slide in the viewport; measuring the live DOM makes this responsive
                // (1-up on narrow screens, 3-up on wide) with no width maths here.
                var off = s.offsetLeft + s.offsetWidth / 2 - track.parentNode.clientWidth / 2;
                track.style.transform = 'translateX(' + (-off) + 'px)';
            }
            document.getElementById('nc-idx').textContent = idx + 1;
            jump.value = idx + 1;
        }

        document.getElementById('nc-prev').onclick = function () { show(idx - 1); };
        document.getElementById('nc-next').onclick = function () { show(idx + 1); };
        document.addEventListener('keydown', function (e) {
            if (e.target === jump) return; // don't hijack keys while typing in the jump box
            if (e.key === 'ArrowLeft') { show(idx - 1); return; }
            if (e.key === 'ArrowRight') { show(idx + 1); return; }
            // a = all seats, n/e/s/w = just that seat — press the matching toolbar button so the
            // click handler (class + highlight) runs, keeping keyboard and buttons in lockstep.
            var k = e.key.toLowerCase();
            var seat = (k === 'a') ? '' : ((k === 'n' || k === 'e' || k === 's' || k === 'w') ? k : null);
            if (seat === null) return;
            var btn = document.querySelector('[data-seat="' + seat + '"]');
            if (btn) btn.click();
        });
        jump.oninput = function () {
            var v = parseInt(jump.value, 10);
            if (v >= 1 && v <= total) show(v - 1);
        };

        // Scroll wheel: down/right = next, up/left = prev (like the arrow keys). preventDefault so the
        // page doesn't also scroll while navigating deals.
        document.querySelector('.viewport').addEventListener('wheel', function (e) {
            if (e.ctrlKey) return; // let Ctrl+wheel zoom the page as usual
            e.preventDefault();
            show(idx + ((e.deltaY + e.deltaX) > 0 ? 1 : -1));
        }, { passive: false });

        // Seat toggle: an empty data-seat means "all"; otherwise show only that seat everywhere.
        var seatBtns = document.querySelectorAll('[data-seat]');
        for (var k = 0; k < seatBtns.length; k++) {
            seatBtns[k].onclick = function () {
                track.classList.remove('only-n', 'only-e', 'only-s', 'only-w');
                var seat = this.getAttribute('data-seat');
                if (seat) track.classList.add('only-' + seat);
                for (var m = 0; m < seatBtns.length; m++) seatBtns[m].classList.toggle('sel', seatBtns[m] === this);
                // The card resize changes the slide width — re-centre now and again once it settles.
                show(idx);
                setTimeout(function () { show(idx); }, 280);
            };
        }

        var parToggle = document.getElementById('nc-par-toggle');
        parToggle.onclick = function () {
            track.classList.toggle('hide-par');
            parToggle.classList.toggle('off');
        };

        window.addEventListener('resize', function () { show(idx); });
        show(0);
    })();
    </script>
</body>
`

// Write the once-per-run prologue for `format`. Only `Html` has one (the page header); every other
// format opens with nothing.
render_page_prologue :: proc(builder: ^strings.Builder, format: Output_Format) {
	#partial switch format {
	case .Html_Handviewer:
		strings.write_string(builder, HTML_PAGE_HEADER)
	case .Html_Cards:
		strings.write_string(builder, HTML_CARDS_PAGE_HEADER)
	}
}

// Write the once-per-run epilogue for `format`. Mirror of `render_page_prologue`.
render_page_epilogue :: proc(builder: ^strings.Builder, format: Output_Format) {
	#partial switch format {
	case .Html_Handviewer:
		strings.write_string(builder, HTML_PAGE_FOOTER)
	case .Html_Cards:
		strings.write_string(builder, HTML_CARDS_PAGE_FOOTER)
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
