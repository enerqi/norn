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
	// (prev/next, ←/→ keys, scroll wheel, deal counter), a seat toggle (show all / just one seat across
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
	// Centre marker: the script fills it per slide — the board number in the 4-hand view, a
	// "Reveal all" button when a single hand is focused. Vulnerability is shown by the seat-pill
	// colours, so it is no longer spelled out here.
	strings.write_string(builder, `<div class="table"></div>`)
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

	// This hand's own high-card points, above the shape line, with how likely that HCP total is:
	// the exact chance of it, then the cumulative chance of that many HCP or fewer (from 0).
	h := hcp(ds[seat])
	hp_exact, hp_cum := hcp_probability(h)
	strings.write_string(builder, `<div class="hcp">`)
	fmt.sbprintf(builder, "%d HCP", h)
	fmt.sbprintf(builder, ` <span class="prob">%.2f%% &middot; %.1f%% &le;</span>`, hp_exact, hp_cum)
	strings.write_string(builder, `</div>`)

	// Optimal point count (honour-combination valuation): the hand's opening starting points for a
	// suit contract and, after it, the notrump variant.
	opc := opc_points(ds[seat])
	fmt.sbprintf(builder, `<div class="opc">OPC: %.1f / %.1f NT</div>`, opc.opening_suit, opc.opening_nt)

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

// A-priori probability that a random 13-card hand holds exactly N high-card points, N = 0..37 by
// index. Exact dealing figures from durangobill.com/BrPtCntStats.html; they sum to 1. Used by
// `hcp_probability` for the per-hand HCP annotation.
@(private)
HCP_PROBABILITY := [38]f64 {
	0.00363896, 0.00788442, 0.0135612, 0.0246236, 0.0384544,
	0.0518619, 0.065541, 0.0802809, 0.0889219, 0.0935623,
	0.0940511, 0.0894468, 0.0802687, 0.0691433, 0.0569332,
	0.0442368, 0.0331092, 0.0236169, 0.0160508, 0.0103617,
	0.00643536, 0.00377867, 0.00210043, 0.00111904, 0.000559034,
	0.000264278, 0.000116683, 4.90666e-05, 1.85677e-05, 6.67165e-06,
	2.19849e-06, 6.11319e-07, 1.71896e-07, 3.52118e-08, 7.06127e-09,
	9.82656e-10, 9.44862e-11, 6.29908e-12,
}

// How likely this hand's HCP total is, as two percentages: `exact` = chance of exactly that many
// HCP, `cumulative` = chance of that many OR FEWER (summed from 0). N outside 0..37 clamps in.
@(private)
hcp_probability :: proc(n: int) -> (exact: f64, cumulative: f64) {
	m := clamp(n, 0, 37)
	cum: f64 = 0
	for i in 0 ..= m {
		cum += HCP_PROBABILITY[i]
	}
	return HCP_PROBABILITY[m] * 100, cum * 100
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
    <title>{{TITLE}}</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet">
    <style>
        body { font-family: 'Open Sans'; }
        .content { margin: auto; max-width: 900px; }
        h1.page-title { text-align: center; }
        iframe { margin-top: 4rem; margin-bottom: 4rem; }
    </style>
</head>
<body class="content">
    <h1 class="page-title">{{TITLE}}</h1>
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
    <title>{{TITLE}}</title>
    <meta charset="utf-8">
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
        /* Scenario name, centred above the carousel. Sits below the pinned toolbar pill (top-left),
           so it never overlaps it. */
        .page-title { text-align: center; margin: 0.4rem 0.5rem 0; font-size: clamp(1rem, 2.6vw, 1.6rem); font-weight: 600; color: var(--ink); }
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
        .prob { color: #b5b5b5; }
        .hcp .prob { font-weight: 400; }
        /* West / table / East grouped and centred, with a gap that grows on wide monitors and shrinks
           at lower resolutions so the hands compress toward one another instead of flinging to the edges. */
        /* A 1fr | auto | 1fr grid: the centre table lands at the exact board centre (aligned with the
           N/S cards above/below) no matter how wide the W/E hands are, while W/E hug the centre gap.
           Top-align (align-items) so the West and East pills line up regardless of card height — the
           dealer's "Dealer" tag makes one card taller, and centring would offset its top-anchored pill. */
        .compass .mid {
            display: grid; grid-template-columns: 1fr auto 1fr; align-items: flex-start;
            column-gap: clamp(0.5rem, 7vw, 6rem);
        }
        .compass .mid > .seat-w { justify-self: end; }
        .compass .mid > .seat-e { justify-self: start; }
        .compass .mid > .table { justify-self: center; align-self: center; }
        /* Card text sizes off the SMALLER of viewport height/width, so it fits both axes — key for
           phones where width is the tight one (landscape) or height is (portrait). */
        .seat {
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: clamp(1rem, min(2.4vh, 4.3vw), 2.2rem);
            line-height: 1.28; min-width: clamp(5rem, 20vw, 11rem);
            background: #fff; border-radius: 10px; padding: 0.85rem 1rem 0.45rem; box-shadow: 0 2px 6px rgba(0,0,0,0.25);
        }
        /* North/South: centre the hand as a block but keep its suit lines left-aligned to the suit
           symbol, so the symbols form a column exactly like East/West (which are already left-aligned). */
        .compass > .seat { width: fit-content; margin: 0 auto; }
        /* The dealer's pill carries a ring that needs clearance from the card's top edge; give EVERY
           seat that clearance (in the base padding above) so the dealer card is not taller than the
           rest — otherwise the E/W pills, centred in the mid row, misalign when exactly one is dealer. */
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
        /* The board's .combo div carries only the raw per-suit distributions (data-suits JSON). To keep
           the board short (no page scroll), inline it is just a ONE-LINE summary — the full interactive
           trick table lives in the CCA overlay panel, which is fixed/out-of-flow so it never adds page
           height. Both are built client-side and react to the toolbar's "tricks >=" slider. */
        .combo {
            margin-top: clamp(0.3rem, 0.8vh, 0.7rem); text-align: center; color: #555;
            font-family: 'Consolas', 'Courier New', monospace; font-size: clamp(0.55rem, 1.35vh, 0.9rem);
        }
        .combo .cmini { font-weight: 700; color: var(--sel); letter-spacing: 0.05em; margin-right: 0.45rem; }
        /* The CCA overlay: a fixed, floating panel with the full trick-chance table for the current
           board. position:fixed keeps it OUT of document flow (the board never grows), and it caps its
           own height and scrolls internally, so the page itself never gains a scrollbar. */
        .cca-panel {
            position: fixed; left: 0.6rem; bottom: 0.6rem; z-index: 20;
            max-width: min(96vw, 44rem); max-height: 78vh; overflow: auto;
            background: #fff; border: 1px solid var(--line); border-radius: 10px;
            box-shadow: 0 6px 24px rgba(0,0,0,0.28); padding: 0.55rem 0.8rem 0.7rem;
        }
        .cca-panel[hidden] { display: none; }
        .cca-head { display: flex; align-items: baseline; gap: 0.6rem; margin-bottom: 0.45rem; }
        .cca-head b { color: var(--ink); }
        .cca-sub { color: #888; font-size: 0.85rem; }
        /* Small pill buttons shared by the head (help / close), the N/S<->E/W side toggle, and the
           IMPs<->MPs objective toggle. */
        .cca-head .x, .cca-head .help, .cca-side .sidebtn, .cca-obj .sidebtn {
            font: inherit; font-size: 0.8rem; border: 1px solid var(--line); background: #f4f4f4;
            color: #555; border-radius: 5px; padding: 0.05rem 0.45rem; cursor: pointer; line-height: 1;
        }
        .cca-side { margin-left: auto; }
        .cca-side, .cca-obj { display: flex; align-items: center; gap: 0.15rem; }
        .cca-side .sidebtn.sel, .cca-obj .sidebtn.sel { background: var(--sel); color: #fff; border-color: var(--sel); }
        .cca-side .sidesep, .cca-obj .sidesep { color: #bbb; }
        .cca-head .help, .cca-head .x { align-self: flex-start; }
        .cca-empty { color: #888; padding: 0.5rem 0.2rem; }
        /* Help modal: a large centred card over a dimmed backdrop, laymen's explanation of the CCA. */
        .cca-help { position: fixed; inset: 0; z-index: 40; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; padding: 1rem; }
        .cca-help[hidden] { display: none; }
        .cca-help-card { position: relative; background: #fff; border-radius: 12px; max-width: min(94vw, 40rem); max-height: 88vh; overflow: auto; padding: 1.2rem 1.4rem 1.4rem; box-shadow: 0 10px 40px rgba(0,0,0,0.35); line-height: 1.5; color: #333; }
        .cca-help-card h2 { margin: 0 0 0.5rem; font-size: 1.2rem; }
        .cca-help-card h3 { margin: 0.95rem 0 0.2rem; font-size: 0.97rem; color: var(--sel); }
        .cca-help-card p { margin: 0.3rem 0; font-size: 0.9rem; }
        .cca-help-card .x { position: absolute; top: 0.6rem; right: 0.7rem; }
        .cca-help-card .sw { display: inline-block; width: 0.75em; height: 0.75em; border-radius: 2px; margin-right: 0.15em; position: relative; top: 0.05em; }
        /* Popup footer: the live P(>= target) headline on the left, and the PER-BOARD "tricks >="
           slider beside it (long, defaults to that board's NS par trick count). */
        .cca-foot { display: flex; align-items: center; flex-wrap: wrap; gap: 0.4rem 1rem; margin-top: 0.5rem; }
        .cca-slider { display: flex; align-items: center; gap: 0.45rem; margin-left: auto; }
        .cca-slider .lbl-txt { color: #666; font-size: 0.82rem; }
        .cca-slider b { font-variant-numeric: tabular-nums; min-width: 1.2em; text-align: right; }
        .cca-slider input[type="range"] { width: 11rem; accent-color: var(--sel); cursor: pointer; }
        .cca-slider input[type="range"]:focus { outline: 2px solid var(--sel); outline-offset: 2px; }
        .ct {
            display: inline-table; border-collapse: collapse;
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: clamp(0.6rem, 1.5vw, 0.9rem); line-height: 1.35; color: #555;
        }
        /* Uniform min-widths so every board's table is the SAME width (the panel then never resizes as
           you flip slides). content-box makes min-width the CONTENT width, so a "100" cell and a "·"
           cell floor to the exact same size regardless of how many digits they hold. */
        .ct th, .ct td { box-sizing: content-box; padding: 0.06rem 0.34rem; text-align: right; font-weight: 400; font-variant-numeric: tabular-nums; min-width: 3ch; }
        .ct thead th { color: #999; font-weight: 600; }
        .ct .sl { text-align: left; font-weight: 700; padding-right: 0.5rem; min-width: 3ch; }
        .ct .suit-s .sl { color: Black; } .ct .suit-h .sl { color: Red; }
        .ct .suit-d .sl { color: Orange; } .ct .suit-c .sl { color: MediumSeaGreen; }
        .ct .tot td, .ct .cum td, .ct .tot th, .ct .cum th { border-top: 1px solid #ddd; }
        /* Phase-2 achievable (single-dummy) total + cumulative rows, in a distinct colour so the gap
           to the double-dummy ceiling (the .tot/.cum rows above) reads at a glance. */
        .ct .totsd td, .ct .cumsd td, .ct .totsd .sl, .ct .cumsd .sl { color: #2f6fd8; }
        .ct .etr { color: #a0a0a0; padding-left: 0.5rem; min-width: 5ch; }
        .ct .etr .eb { color: #2f6fd8; }  /* the blind (single-dummy) expected tricks */
        .ct .ln { text-align: left; color: #777; padding-left: 0.55rem; min-width: 5ch; font-size: 0.92em; }
        .ct .ln[data-tip] { cursor: help; text-decoration: underline dotted #aaa; text-underline-offset: 2px; }
        /* Hover tooltip: the detailed play narration for a suit's recommended line. */
        .cca-tip { position: fixed; z-index: 50; max-width: 22rem; background: #222; color: #fff; padding: 0.4rem 0.6rem; border-radius: 6px; font-size: 0.82rem; line-height: 1.35; box-shadow: 0 4px 16px rgba(0,0,0,0.35); pointer-events: none; }
        .cca-tip[hidden] { display: none; }
        /* The target column, driven by the "tricks >=" slider — header cell + cumulative cell. Target
           the CELL (td/th.hl) so this out-specifies the coloured .totsd/.cumsd row rules above —
           otherwise the blue SD text stayed blue on the blue highlight and was unreadable. */
        .ct td.hl, .ct th.hl { background: var(--sel); color: #fff !important; border-radius: 3px; }
        .ct-head { margin-top: 0.45rem; font-weight: 600; color: #333; font-size: clamp(0.8rem, 1.6vw, 1rem); }
        /* Seat toggle: keep just one seat visible across every board (layout preserved via visibility). */
        /* Single-seat view: the other three seats collapse to just their position pill (and Dealer tag),
           so the compass orientation, vulnerability, and dealer stay visible — only their cards hide. */
        /* Seat focus is now PER BOARD (a .slide class), not global on the track: each board can show
           all four hands or one, independently. */
        .slide.only-n .seat:not(.seat-n), .slide.only-e .seat:not(.seat-e),
        .slide.only-s .seat:not(.seat-s), .slide.only-w .seat:not(.seat-w) {
            background: transparent; box-shadow: none; min-width: 0; padding: 0.2rem;
        }
        .slide.only-n .seat:not(.seat-n) :is(.suit, .hcp, .opc, .shape),
        .slide.only-e .seat:not(.seat-e) :is(.suit, .hcp, .opc, .shape),
        .slide.only-s .seat:not(.seat-s) :is(.suit, .hcp, .opc, .shape),
        .slide.only-w .seat:not(.seat-w) :is(.suit, .hcp, .opc, .shape) { display: none; }
        /* The Dealer tag sits on the green felt for these markers (transparent card), so make it white. */
        .slide.only-n .seat:not(.seat-n) .dtag, .slide.only-e .seat:not(.seat-e) .dtag,
        .slide.only-s .seat:not(.seat-s) .dtag, .slide.only-w .seat:not(.seat-w) .dtag { color: #fff; }
        /* The chosen seat grows by REAL layout (font-size, everything inside is em-relative), so the
           green felt reflows to contain it — a transform would leave the card spilling off a small felt. */
        .seat { transition: font-size 0.25s ease; }
        .slide.only-n .seat-n, .slide.only-e .seat-e,
        .slide.only-s .seat-s, .slide.only-w .seat-w { font-size: clamp(1.6rem, min(4vh, 6.5vw), 3.4rem); }
        /* The partnership HCP summary is meaningless with only one hand shown, so hide it then. */
        .slide.only-n .stats, .slide.only-e .stats,
        .slide.only-s .stats, .slide.only-w .stats { display: none; }
        /* The seat pill is the board's "compass icon": in the 4-hand view it is clickable to focus
           that hand. Once a hand is focused you must Reveal all before switching, so no pointer then. */
        .slide:not([class*="only-"]) .seat .lbl { cursor: pointer; }
        .slide:not([class*="only-"]) .seat .lbl:hover { filter: brightness(1.12); }
        /* Centre marker: a plain board-number label in the 4-hand view; a "Reveal all" button (the
           script adds .reveal + the text) when a single hand is focused. */
        .table.reveal { cursor: pointer; background: rgba(255,255,255,0.22); }
        .table.reveal:hover { background: rgba(255,255,255,0.35); }
        /* Single East/West focus: replace the 1fr|auto|1fr grid with a content-hugging flex row so the
           felt wraps the big card (the grid's equal 1fr columns would mirror its width as empty green on
           the far side), and centre the items vertically so the opposite pill + Reveal-all button sit
           level with the enlarged hand. North/South focus keeps the grid (the big card is outside .mid). */
        .slide.only-e .mid, .slide.only-w .mid {
            display: flex; justify-content: center; align-items: center; gap: clamp(0.5rem, 7vw, 6rem);
        }
        /* Par/combo captions describe the whole board, so hide them while a single hand is focused —
           they only make sense (and only show) in that board's 4-hand view. */
        .slide[class*="only-"] .par, .slide[class*="only-"] .combo { display: none; }
        .track.hide-par .par, .track.hide-par .combo { display: none; }

        /* Phones: strip the secondary lines (OPC/shape), pull the hands tight together, and shrink the
           HCP badge + centre table so a whole board fits a small screen in either orientation. */
        @media (max-width: 640px) {
            .opc, .shape { display: none; }
            .seat { min-width: 0; padding: 0.7rem 0.6rem 0.35rem; }
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
        <div class="group">
            <span class="lbl-txt">seats</span>
            <button data-seat="" class="sel">All</button>
            <button data-seat="n">N</button>
            <button data-seat="e">E</button>
            <button data-seat="s">S</button>
            <button data-seat="w">W</button>
        </div>
        <button id="nc-reset" title="Reset every board to the current seat default">Reset</button>
        <button id="nc-par-toggle">Par</button>
        <button id="nc-cca-toggle" title="Card Combination Analyser: open the full trick-chance table for the current board">CCA</button>
    </div>
    <h1 class="page-title">{{TITLE}}</h1>
    <div class="viewport">
        <div class="track" id="nc-track">
`

// The footer for an `Html_Cards` run: closes the track/viewport, then the script that turns the
// flat sequence of compass (and par) elements into slides and drives the carousel.
@(private = "file")
HTML_CARDS_PAGE_FOOTER :: `        </div>
    </div>
    <div class="cca-panel" id="nc-cca" hidden>
        <div class="cca-head">
            <b>Card Combination Analyser</b>
            <span class="cca-sub" id="nc-cca-sub"></span>
            <span class="cca-side" title="Which partnership's tricks to analyse">
                <button class="sidebtn sel" id="nc-cca-ns">N/S</button><span class="sidesep">|</span><button class="sidebtn" id="nc-cca-ew">E/W</button>
            </span>
            <span class="cca-obj" title="Scoring: IMPs = make the contract; MPs = chase overtricks while better than even">
                <button class="sidebtn sel" id="nc-cca-imps">IMPs</button><span class="sidesep">|</span><button class="sidebtn" id="nc-cca-mps">MPs</button>
            </span>
            <button class="help" id="nc-cca-help" title="What is this?">?</button>
            <button class="x" id="nc-cca-close" title="Close">&#10005;</button>
        </div>
        <div id="nc-cca-body"></div>
        <div class="cca-foot">
            <span class="ct-head" id="nc-cca-headline"></span>
            <span class="cca-slider">
                <span class="lbl-txt">tricks &ge;</span>
                <input id="nc-cca-target" type="range" min="1" max="13">
                <b id="nc-cca-target-val"></b>
            </span>
        </div>
    </div>
    <div class="cca-help" id="nc-cca-help-modal" hidden>
        <div class="cca-help-card">
            <button class="x" id="nc-cca-help-close" title="Close">&#10005;</button>
            <h2>Card Combination Analyser &mdash; what am I looking at?</h2>
            <p>It estimates, for one partnership on <b>this</b> deal, how many <b>tricks</b> they can win &mdash;
               suit by suit and in total &mdash; given the cards they hold and all the ways the opponents' cards
               might be split. It is a quick guide to "how high can we go?", not the last word.</p>
            <h3>The table</h3>
            <p>Each row <b>&spades; &hearts; &diams; &clubs;</b> is one suit. The columns <code>0&hellip;13</code>
               are the chance of taking <i>exactly</i> that many tricks in the suit. The <b>E</b> column is the
               average number of tricks &mdash; <b>double-dummy / <span style="color:#2f6fd8">blind</span></b>
               (the blue figure is what you'd take playing blind, always the smaller). The <b>line</b> column
               is the suggested way to play that suit blind: <i>cash</i> (bang out top cards), <i>finesse</i>,
               or <i>duck</i> (give up an early round). It is a simplified pick from a few standard plays &mdash;
               a real best line can <i>combine</i> them (e.g. duck a round <i>then</i> finesse), which the one
               word can't show, so read it as the general idea, not an exact recipe. <b>Hover the line word</b>
               for a fuller, cards-specific plan.</p>
            <h3>Two answers: ceiling vs. realistic</h3>
            <p><span class="sw" style="background:#222"></span><b>tot</b> and <b>&ge;k</b> (black) &mdash; the
               <b>double-dummy</b> ceiling: how it would go if you could <i>see all four hands</i>. Best case /
               hindsight &mdash; usually better than real life.</p>
            <p><span class="sw" style="background:#2f6fd8"></span><b>sd</b> and <b>&ge;sd</b> (blue) &mdash; the
               <b>single-dummy</b>, realistic figure: playing <i>blind</i> to the opponents' cards, so you must
               guess (finesses, which way to play). This is closer to what you'll actually take.</p>
            <p>The gap between black and blue is the price of not seeing the cards. <b>&ge;sd</b> is the best you
               can do by choosing the smartest line in each suit for the target you set below.</p>
            <h3>The "tricks &ge;" slider</h3>
            <p>Sets the target: the chance of taking <b>at least</b> that many tricks. E.g. set it to 9 for a
               game in no-trumps, 10 for a major-suit game. The headline shows the ceiling (DD) and realistic
               (SD) chance of reaching it.</p>
            <h3>N/S vs E/W</h3>
            <p>The two buttons at the top switch <i>whose</i> tricks are analysed &mdash; your side or the
               opponents'.</p>
            <h3>IMPs vs Matchpoints</h3>
            <p><b>IMPs</b> (teams): just <i>make the contract</i>. The recommended play is the safest one for
               the target you set &mdash; overtricks barely matter, going down is costly.</p>
            <p><b>MPs</b> (pairs / matchpoints): you're ranked against everyone else in your contract, so
               <i>overtricks win boards</i>. The tool then chases the extra trick while it stays better than
               even &mdash; it aims for the <b>highest</b> number of tricks whose chance is still at least
               50%. The headline shows that "aim" (and still tells you the plain make chance).</p>
            <h3>The small print</h3>
            <p>It treats the four suits independently and assumes you can always get to the right hand ("free
               entries"). Real play has entry problems and suits interact, so treat the numbers as a
               <b>guide</b>, not a guarantee. The double-dummy <b>par</b> caption on the board is the exact
               best-play result.</p>
        </div>
    </div>
    <div class="cca-tip" id="nc-cca-tip" hidden></div>
    <script>
    (function () {
        var track = document.getElementById('nc-track');
        // Each accepted deal wrote a .compass and (with --dd) one or more following caption siblings
        // (a .par par-summary, a .combo trick table, ...). Group each compass with every sibling up to
        // the next board into one .slide, so the carousel moves them together.
        var comps = Array.prototype.slice.call(track.querySelectorAll(':scope > .compass'));
        var slides = comps.map(function (c) {
            var slide = document.createElement('div');
            slide.className = 'slide';
            track.insertBefore(slide, c);
            slide.appendChild(c);
            // Pull in trailing siblings (captions, and the whitespace text nodes between them) until the
            // next .compass — those all belong to this board.
            while (slide.nextSibling) {
                var sib = slide.nextSibling;
                if (sib.nodeType === 1 && sib.classList && sib.classList.contains('compass')) break;
                slide.appendChild(sib);
            }
            return slide;
        });

        var idx = 0;
        var total = slides.length;
        document.getElementById('nc-total').textContent = total;

        // Seat focus is per board. globalSeat is the toolbar default ('' = all four hands, else one
        // of n/e/s/w). override[i] is an explicit per-board choice that WINS over the default — set
        // by clicking a hand's pill (focus it) or "Reveal all" (show all four). A board with no
        // override follows the global default; Reset drops every override.
        var globalSeat = '';
        var override = new Array(total); // undefined = follow globalSeat
        function seatFor(i) { return override[i] !== undefined ? override[i] : globalSeat; }
        function applySeat(i) {
            var s = slides[i];
            s.classList.remove('only-n', 'only-e', 'only-s', 'only-w');
            var seat = seatFor(i);
            if (seat) s.classList.add('only-' + seat);
            var table = s.querySelector('.table');
            if (table) {
                if (seat) { table.textContent = 'Reveal all'; table.classList.add('reveal'); }
                else { table.textContent = 'Board ' + (i + 1); table.classList.remove('reveal'); }
            }
        }
        function applyAll() { for (var i = 0; i < total; i++) applySeat(i); }
        // A focus/reveal reflows the felt (font-size transition): re-centre now and after it settles.
        function recentre() { show(idx); setTimeout(function () { show(idx); }, 280); }

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
            // Rebuild the overlay for the new board now, but place it only AFTER the slide's
            // scale(0.9->1) transition finishes — the par-caption geometry is still animating here, so
            // positioning now would mis-place (drift) the panel. One reposition on the settled layout.
            renderCca(false);
            clearTimeout(ccaPosT);
            ccaPosT = setTimeout(positionCca, 380);
        }

        document.getElementById('nc-prev').onclick = function () { show(idx - 1); };
        document.getElementById('nc-next').onclick = function () { show(idx + 1); };
        document.addEventListener('keydown', function (e) {
            // When a form control is focused (the target slider), let it handle keys natively — arrows
            // then nudge the slider one trick, and the carousel shortcuts below are suppressed.
            var t = e.target;
            if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT')) return;
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

        // Scroll wheel: down/right = next, up/left = prev (like the arrow keys). preventDefault so the
        // page doesn't also scroll while navigating deals.
        document.querySelector('.viewport').addEventListener('wheel', function (e) {
            if (e.ctrlKey) return; // let Ctrl+wheel zoom the page as usual
            e.preventDefault();
            show(idx + ((e.deltaY + e.deltaX) > 0 ? 1 : -1));
        }, { passive: false });

        // Toolbar seat buttons set the GLOBAL default (empty data-seat = all four hands). Per-board
        // overrides are kept — the default only moves boards you haven't focused individually.
        var seatBtns = document.querySelectorAll('[data-seat]');
        for (var k = 0; k < seatBtns.length; k++) {
            seatBtns[k].onclick = function () {
                globalSeat = this.getAttribute('data-seat');
                for (var m = 0; m < seatBtns.length; m++) seatBtns[m].classList.toggle('sel', seatBtns[m] === this);
                applyAll();
                recentre();
            };
        }

        // Reset: drop every per-board override so all boards follow the global default again.
        document.getElementById('nc-reset').onclick = function () {
            for (var i = 0; i < total; i++) override[i] = undefined;
            applyAll();
            recentre();
        };

        // Delegated board clicks. A hand's pill is its "compass icon": click it — only from the
        // 4-hand view — to focus that hand. When a hand is focused the centre marker is a "Reveal
        // all" button back to four hands. You cannot jump hand->hand; reveal all first.
        track.addEventListener('click', function (e) {
            var slideEl = e.target.closest('.slide');
            if (!slideEl) return;
            var i = slides.indexOf(slideEl);
            if (i < 0) return;
            if (e.target.closest('.table')) {
                if (seatFor(i)) { override[i] = ''; applySeat(i); recentre(); } // Reveal all
                return;
            }
            var lbl = e.target.closest('.lbl');
            if (!lbl) return;
            if (seatFor(i)) return; // single-hand view: Reveal all before switching
            var seatEl = lbl.closest('.seat');
            var m = seatEl && seatEl.className.match(/seat-([nesw])/);
            if (!m) return;
            override[i] = m[1];
            applySeat(i);
            recentre();
        });

        var parToggle = document.getElementById('nc-par-toggle');
        parToggle.onclick = function () {
            track.classList.toggle('hide-par');
            parToggle.classList.toggle('off');
        };

        // --- Combo trick-chance analysis (client-side) ---------------------------------------
        // Each board's .combo div carries ONLY raw per-suit p[k] arrays (data-suits JSON, from the
        // combo annotator). We convolve the four suits here. The target is PER BOARD: it defaults to
        // that board's NS par trick count (data-target on the board's .par caption, from the dd
        // annotator) and is adjustable via the slider at the bottom of the CCA overlay. INLINE the
        // .combo is a one-line summary; the full trick table lives in the CCA overlay (a fixed panel,
        // out of page flow) for the ACTIVE board only. A run with no combo data has no .combo divs.
        function convolve(a, b) {
            var out = []; for (var i = 0; i < 14; i++) out[i] = 0;
            for (var i = 0; i < 14; i++) { if (!a[i]) continue; for (var j = 0; i + j < 14; j++) out[i + j] += a[i] * b[j]; }
            return out;
        }
        function comboTotal(suits) {
            var t = []; for (var i = 0; i < 14; i++) t[i] = 0; t[0] = 1;
            ['s', 'h', 'd', 'c'].forEach(function (k) { t = convolve(t, suits[k] || []); });
            return t;
        }
        function tail(total, t) { var p = 0; for (var k = t; k < 14; k++) p += total[k]; return p; }
        function pctCell(p) { return p < 0.005 ? '·' : Math.round(p * 100); }
        function etr(arr) { var s = 0; for (var k = 0; k < 14; k++) s += k * (arr[k] || 0); return s; }

        // Each board's .combo carries SIX blobs: per-suit census + achievable-single-dummy + the
        // adaptive P(>=t) make curve, for BOTH partnerships (data-ns.., data-ew..). We keep both sides so
        // the N/S to E/W toggle just switches which one renders. ccaSide is the global choice.
        var ccaSide = 'ns';
        var ccaObj = 'imps'; // scoring objective: 'imps' (make the target) or 'mps' (chase overtricks)
        function parseAttr(el, a) { try { return JSON.parse(el.getAttribute(a)); } catch (e) { return null; } }
        // What to play for, given the analysed side S and the contract target. IMPs just makes the
        // target (safety). MPs chases overtricks: aim as high as the odds stay better than even —
        // the highest k (>= target) whose achievable chance P(>=k) is still >= 50%. aim is the
        // recommended trick count, atl[aim] its chance; both fall back to the target when no overtrick
        // is worth it or when the adaptive curve is absent.
        function recommend(S, target) {
            var aim = target;
            if (ccaObj === 'mps' && S.atl) {
                for (var k = target + 1; k <= 13; k++) { if (S.atl[k] >= 0.5) aim = k; else break; }
            }
            return { aim: aim, makePct: S.atl ? S.atl[target] : tail(S.total, target),
                     aimPct: S.atl ? S.atl[aim] : tail(S.total, aim) };
        }
        var combos = Array.prototype.slice.call(document.querySelectorAll('.combo'));
        combos.forEach(function (el) {
            var ns = parseAttr(el, 'data-ns'); if (!ns) return;
            function side(pfx) {
                var data = parseAttr(el, 'data-' + pfx);
                var sd = parseAttr(el, 'data-' + pfx + '-sd');
                return { data: data, sd: sd, atl: parseAttr(el, 'data-' + pfx + '-atl'),
                         lines: parseAttr(el, 'data-' + pfx + '-lines'), tips: parseAttr(el, 'data-' + pfx + '-tips'),
                         total: comboTotal(data), totalSd: sd ? comboTotal(sd) : null };
            }
            el._sides = { ns: side('ns'), ew: side('ew') };
            // Per-board default target = this board's NS par trick count (dd's .par data-target), else 9.
            var slide = el.closest('.slide');
            var par = slide ? slide.querySelector('.par') : null;
            var d = par && par.getAttribute('data-target');
            el._target = d ? Math.max(1, Math.min(13, +d)) : 9;
        });
        function sideData(el) { return el._sides ? el._sides[ccaSide] : null; }
        // The inline one-liner for a board: CCA badge (with the analysed side) + P(>= target), both the
        // double-dummy ceiling (DD) and the achievable single-dummy optimum (SD, from the adaptive curve).
        function comboLine(el) {
            var S = sideData(el); if (!S || !S.total) return;
            var t = el._target, dd = (tail(S.total, t) * 100).toFixed(0), r = recommend(S, t);
            var s = '<span class="cmini">CCA ' + ccaSide.toUpperCase() + ' ' + ccaObj.toUpperCase() + '</span> ';
            if (ccaObj === 'mps' && r.aim > t) {
                s += 'aim ' + r.aim + ': SD ' + (r.aimPct * 100).toFixed(0) + '% &middot; make ' + t + ': SD ' + (r.makePct * 100).toFixed(0) + '%';
            } else {
                s += 'P(&ge;' + t + ') = DD ' + dd + '% &middot; SD ' + (r.makePct * 100).toFixed(0) + '%';
            }
            s += ' &middot; E[tot] = ' + etr(S.total).toFixed(1) + (S.totalSd ? ' / ' + etr(S.totalSd).toFixed(1) : '');
            el.innerHTML = s;
        }
        // The full per-suit table for the active board & side. Per-suit rows + the "tot"/"≥k" pair are
        // the double-dummy CENSUS (ceiling). The "sd" row is a realistic single-dummy line's shape; the
        // "≥sd" row is the ADAPTIVE optimum P(>=k) (best line per suit for that target) — the gap from
        // the black rows is the double-dummy tax.
        // Friendly labels for the recommended blind line per suit.
        function lineLabel(n) { return n === 'top-down' ? 'cash' : n === 'duck-one' ? 'duck' : n === 'finesse' ? 'finesse' : (n || ''); }
        function escAttr(s) { return (s || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;'); }
        function ctTableHTML(S) {
            var data = S.data, total = S.total, totalSd = S.totalSd, atl = S.atl, sd = S.sd, lines = S.lines, tips = S.tips;
            var rows = [['s', '♠'], ['h', '♥'], ['d', '♦'], ['c', '♣']];
            var h = '<table class="ct"><thead><tr><th></th>';
            for (var k = 0; k < 14; k++) h += '<th data-k="' + k + '">' + k + '</th>';
            // Per-suit E is shown as double-dummy / blind (dd / sd); "line" is the recommended blind play.
            h += '<th class="etr" title="expected tricks: double-dummy / blind">E</th><th class="ln" title="recommended blind line">line</th></tr></thead><tbody>';
            rows.forEach(function (o, i) {
                var arr = data[o[0]] || [], sdArr = sd && sd[o[0]];
                h += '<tr class="suit-' + o[0] + '"><td class="sl">' + o[1] + '</td>';
                for (var k = 0; k < 14; k++) h += '<td>' + pctCell(arr[k] || 0) + '</td>';
                h += '<td class="etr">' + etr(arr).toFixed(1) + (sdArr ? ' <span class="eb">/ ' + etr(sdArr).toFixed(1) + '</span>' : '') + '</td>';
                var tip = tips && tips[i];
                h += '<td class="ln"' + (tip ? ' data-tip="' + escAttr(tip) + '"' : '') + '>' + (lines ? lineLabel(lines[i]) : '') + '</td></tr>';
            });
            h += '<tr class="tot"><td class="sl">tot</td>';
            for (var k = 0; k < 14; k++) h += '<td>' + pctCell(total[k]) + '</td>';
            h += '<td class="etr">' + etr(total).toFixed(1) + '</td><td class="ln"></td></tr>';
            h += '<tr class="cum"><td class="sl">≥k</td>';
            for (var k = 0; k < 14; k++) h += '<td data-k="' + k + '">' + pctCell(tail(total, k)) + '</td>';
            h += '<td class="etr"></td><td class="ln"></td></tr>';
            if (totalSd) {
                h += '<tr class="tot totsd"><td class="sl">sd</td>';
                for (var k = 0; k < 14; k++) h += '<td>' + pctCell(totalSd[k]) + '</td>';
                h += '<td class="etr">' + etr(totalSd).toFixed(1) + '</td><td class="ln"></td></tr>';
            }
            if (atl) {
                h += '<tr class="cum cumsd"><td class="sl">≥sd</td>';
                for (var k = 0; k < 14; k++) h += '<td data-k="' + k + '">' + pctCell(atl[k]) + '</td>';
                h += '<td class="etr"></td><td class="ln"></td></tr>';
            }
            h += '</tbody></table>';
            return h;
        }

        // CCA overlay: full table for the ACTIVE board, with the per-board target slider in its footer.
        var ccaPanel = document.getElementById('nc-cca');
        var ccaBody = document.getElementById('nc-cca-body');
        var ccaSub = document.getElementById('nc-cca-sub');
        var ccaBtn = document.getElementById('nc-cca-toggle');
        var ccaHead = document.getElementById('nc-cca-headline');
        var ccaSlider = document.getElementById('nc-cca-target');
        var ccaSliderVal = document.getElementById('nc-cca-target-val');
        var ccaFoot = document.querySelector('.cca-foot');
        var ccaOpen = false;
        var ccaPosT; // pending "reposition after the slide transition settles" timer
        function activeCombo() { var s = slides[idx]; return s ? s.querySelector('.combo') : null; }
        // Rebuild the overlay for the active board. pos=true places it now (for the no-transition
        // callers: opening the panel, resize); during a slide NAV the caller instead waits for the
        // scale(0.9->1) transition to finish before positioning (measuring par mid-transition mis-placed
        // the panel).
        function renderCca(pos) {
            if (!ccaOpen) return;
            var el = activeCombo(), S = el && sideData(el);
            if (!S || !S.total) {
                ccaBody.innerHTML = '<div class="cca-empty">No combination data for this board.</div>';
                ccaSub.textContent = '';
                if (ccaFoot) ccaFoot.style.visibility = 'hidden';
                return;
            }
            if (ccaFoot) ccaFoot.style.visibility = 'visible';
            ccaBody.innerHTML = ctTableHTML(S);
            ccaSub.textContent = 'Board ' + (idx + 1);
            ccaSlider.value = el._target;
            hlCca();
            if (pos) positionCca();
        }
        // Place the (fixed) panel at its NATURAL content size (the table width is constant across
        // slides, so the panel never resizes as you navigate), anchored BOTTOM-LEFT. On wide screens
        // the board is centred with a left gutter, so bottom-left already sits clear of the centred
        // par/combo captions. As the screen narrows the board slides left under the panel; once the
        // panel would COVER those captions, LIFT it so its bottom sits just ABOVE them (over the felt)
        // rather than hiding the par score. No width/height overrides -> no per-slide resize, no forced
        // internal scrollbar.
        function positionCca() {
            if (!ccaOpen) return;
            var slide = slides[idx];
            if (!slide) return;
            var vh = window.innerHeight, M = 10;
            var s = ccaPanel.style;
            s.top = s.right = s.maxWidth = s.maxHeight = ''; // natural size; CSS caps width/height
            s.left = M + 'px';
            s.bottom = M + 'px';
            var pr = ccaPanel.getBoundingClientRect();
            // Top-most caption (par, then the combo one-liner) that overlaps the panel horizontally.
            var capTop = Infinity;
            ['.par', '.combo'].forEach(function (sel) {
                var c = slide.querySelector(sel);
                if (!c) return;
                var cr = c.getBoundingClientRect();
                if (cr.height > 0 && cr.right > pr.left && cr.left < pr.right) capTop = Math.min(capTop, cr.top);
            });
            if (capTop !== Infinity && pr.bottom > capTop) {
                // Would cover a caption: raise the panel to sit M above it (clamped to the top of screen).
                var lift = vh - capTop + M;          // css bottom putting the panel's bottom M above capTop
                var maxLift = vh - pr.height - M;     // highest possible (panel top at M)
                s.bottom = Math.max(M, Math.min(lift, maxLift)) + 'px';
            }
        }
        // Highlight the target column + set the headline/slider value for the ACTIVE board's target.
        function hlCca() {
            if (!ccaOpen) return;
            var el = activeCombo(), S = el && sideData(el);
            if (!S || !S.total) return;
            var t = el._target, r = recommend(S, t);
            if (ccaSliderVal) ccaSliderVal.textContent = t;
            // Highlight the column we're actually playing for (= target under IMPs, the overtrick aim
            // under MPs).
            var cells = ccaBody.querySelectorAll('[data-k]');
            for (var i = 0; i < cells.length; i++)
                cells[i].classList.toggle('hl', +cells[i].getAttribute('data-k') === r.aim);
            if (ccaHead) {
                var dd = (tail(S.total, t) * 100).toFixed(1);
                if (ccaObj === 'mps' && r.aim > t) {
                    ccaHead.textContent = 'MPs — aim ' + r.aim + ': SD ' + (r.aimPct * 100).toFixed(1) +
                        '%   (make ' + t + ': SD ' + (r.makePct * 100).toFixed(1) + '%)';
                } else if (S.atl) {
                    ccaHead.textContent = (ccaObj === 'mps' ? 'MPs' : 'IMPs') + ' — make ' + t +
                        ':  DD ' + dd + '%  ·  SD ' + (r.makePct * 100).toFixed(1) + '%';
                } else {
                    ccaHead.textContent = 'P(≥ ' + t + ' tricks) = ' + dd + '%';
                }
            }
        }
        function setCca(open) {
            ccaOpen = open; ccaPanel.hidden = !open;
            if (ccaBtn) ccaBtn.classList.toggle('sel', open);
            renderCca(true); // opening: no slide transition in flight, place immediately
        }
        if (ccaBtn) ccaBtn.onclick = function () { setCca(!ccaOpen); };
        document.getElementById('nc-cca-close').onclick = function () { setCca(false); };
        // Slider adjusts the ACTIVE board's target only; the inline summary + overlay update together.
        if (ccaSlider) ccaSlider.oninput = function () {
            var el = activeCombo();
            if (!el) return;
            el._target = +this.value;
            comboLine(el);
            hlCca();
        };
        // N/S <-> E/W toggle: global choice, re-render the overlay + every inline one-liner.
        var nsBtn = document.getElementById('nc-cca-ns'), ewBtn = document.getElementById('nc-cca-ew');
        function setSide(s) {
            ccaSide = s;
            if (nsBtn) nsBtn.classList.toggle('sel', s === 'ns');
            if (ewBtn) ewBtn.classList.toggle('sel', s === 'ew');
            combos.forEach(comboLine);
            renderCca(true);
        }
        if (nsBtn) nsBtn.onclick = function () { setSide('ns'); };
        if (ewBtn) ewBtn.onclick = function () { setSide('ew'); };
        // IMPs <-> MPs objective toggle: global, re-render overlay + inline lines.
        var impsBtn = document.getElementById('nc-cca-imps'), mpsBtn = document.getElementById('nc-cca-mps');
        function setObj(o) {
            ccaObj = o;
            if (impsBtn) impsBtn.classList.toggle('sel', o === 'imps');
            if (mpsBtn) mpsBtn.classList.toggle('sel', o === 'mps');
            combos.forEach(comboLine);
            renderCca(true);
        }
        if (impsBtn) impsBtn.onclick = function () { setObj('imps'); };
        if (mpsBtn) mpsBtn.onclick = function () { setObj('mps'); };
        // Help modal.
        var helpModal = document.getElementById('nc-cca-help-modal');
        var helpBtn = document.getElementById('nc-cca-help'), helpClose = document.getElementById('nc-cca-help-close');
        if (helpBtn) helpBtn.onclick = function () { if (helpModal) helpModal.hidden = false; };
        if (helpClose) helpClose.onclick = function () { if (helpModal) helpModal.hidden = true; };
        if (helpModal) helpModal.onclick = function (e) { if (e.target === helpModal) helpModal.hidden = true; };
        // Hover tooltip: the detailed play narration for a suit's recommended line (delegation, since the
        // table is rebuilt on every nav / toggle).
        var tipEl = document.getElementById('nc-cca-tip');
        function posTip(e) {
            if (!tipEl) return;
            var m = 14;
            tipEl.style.left = Math.min(e.clientX + m, window.innerWidth - tipEl.offsetWidth - 8) + 'px';
            tipEl.style.top = Math.min(e.clientY + m, window.innerHeight - tipEl.offsetHeight - 8) + 'px';
        }
        function tipTarget(e) { return e.target && e.target.closest ? e.target.closest('[data-tip]') : null; }
        document.addEventListener('mouseover', function (e) {
            var t = tipTarget(e);
            if (t && tipEl) { tipEl.textContent = t.getAttribute('data-tip'); tipEl.hidden = false; posTip(e); }
        });
        document.addEventListener('mousemove', function (e) { if (tipEl && !tipEl.hidden) posTip(e); });
        document.addEventListener('mouseout', function (e) { if (tipTarget(e) && tipEl) tipEl.hidden = true; });

        if (combos.length === 0 && ccaBtn) ccaBtn.style.display = 'none';

        window.addEventListener('resize', function () { show(idx); });
        applyAll();
        combos.forEach(comboLine);
        show(0);
    })();
    </script>
</body>
`

// Write the once-per-run prologue for `format`. Only the HTML formats have one (the page header);
// every other format opens with nothing. `page_title` (empty -> "Practice Deals") fills both the
// document `<title>` and the on-page `<h1>` via the `{{TITLE}}` token baked into the header literals.
render_page_prologue :: proc(builder: ^strings.Builder, format: Output_Format, page_title := "") {
	header: string
	#partial switch format {
	case .Html_Handviewer:
		header = HTML_PAGE_HEADER
	case .Html_Cards:
		header = HTML_CARDS_PAGE_HEADER
	case:
		return
	}
	title := page_title if page_title != "" else "Practice Deals"
	// replace_all into the temp allocator: no manual free, and the whole header is written this frame.
	page, _ := strings.replace_all(header, "{{TITLE}}", title, context.temp_allocator)
	strings.write_string(builder, page)
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
