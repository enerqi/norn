package norn

/*
	render.odin — turning a dealt deal into text.

	This is the presentation layer: a pure transform from a `Deal` to its textual form. It does NOT
	send anything anywhere — choosing a destination (stdout, a file) is the driver's job in
	generate.odin. Different consumers want different shapes, so rendering is pluggable:
	`Output_Format` selects a renderer and `render_deal` dispatches to it. Adding a new format (e.g.
	HTML, or BBO handviewer query parameters) later means adding one enum value and one renderer —
	nothing else changes.

	All renderers write into a `strings.Builder` supplied by the caller. Keeping the string-building
	pure (deal in, text in a builder, no I/O) is what makes these functions exhaustively testable
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

// The available text renderings of a deal.
Output_Format :: enum {
	// `Line` is the one-deal-per-line format this program exists to produce — the same shape as
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
	// driver). This is the Odin equivalent of the `run-deal.py --html-output-path` export. Every deal
	// is a live handviewer that loads from bridgebase.com; for an offline, self-rendered page see
	// `Html_Cards`.
	Html_Handviewer,
	// `Html_Cards` is a self-contained, offline HTML page: every deal is drawn as a text compass
	// diagram (four hands, suit glyph + ranks) inside a client-side carousel — no BBO iframe, no remote
	// load. The page header (emitted once) carries the carousel shell, CSS, and a static `<script>`
	// that groups each rendered deal (+ its optional par caption) into a slide and wires the nav
	// (prev/next, ←/→ keys, scroll wheel, deal counter), a seat toggle (show all / just one seat across
	// every deal), and a par toggle. Per deal this renderer emits only the compass `<div>`; the par
	// caption is appended by the consumer's annotator as a following `.par` sibling (the script pairs
	// them). Unlike `Html` it never contacts the network, so nav is instant and it works offline.
	Html_Cards,
	// `Pbn` is the Portable Bridge Notation deal tag, one deal per line:
	//
	//	[Deal "N:T84.QJ.KQ976.A52 Q9.AK87.J8.KQ964 KJ32.T96.AT.J873 A765.5432.543.T"]
	//
	// One hand per seat in clockwise order from the prefix seat (N E S W), each hand's four suits in
	// S.H.D.C order separated by '.', ranks high-to-low, a void written as the empty string (adjacent
	// dots). This is the `[Deal]` tag every PBN importer reads; the surrounding per-deal tags of a
	// full PBN export (Event, Board, Dealer, …) are intentionally omitted — add them only if a strict
	// importer needs them. Matches deal's `pbn` formatter for the deal field itself.
	Pbn,
	// `Numeric` is deal's compact `numeric` format: a 52-character digit string per deal, one digit
	// per card giving its owner seat (North 0, East 1, South 2, West 3). The cards are walked in a
	// fixed order — suits S H D C, and within each suit ranks high-to-low A K Q J T 9 .. 2 — so the
	// position encodes the card and the digit encodes who holds it. No separators; reversible back to
	// a full deal. (The seat digits coincide with norn's `Seat` backing values.)
	Numeric,
}

// Render `deal` into `builder` using the chosen `format`. `randomize_table` only affects the
// handviewer-based formats: when true the vulnerability and dealer are drawn from
// `context.random_generator`; when false they are fixed (`v=-`, `d=n`) so output stays deterministic.
render_deal :: proc(builder: ^strings.Builder, deal: Deal, format: Output_Format, randomize_table := false) {
	switch format {
	case .Line:
		render_deal_line(builder, deal)
	case .Pretty:
		render_deal_pretty(builder, deal)
	case .Handviewer:
		render_deal_handviewer(builder, deal, randomize_table)
	case .Html_Handviewer:
		render_deal_html_iframe(builder, deal, randomize_table)
	case .Html_Cards:
		render_deal_html_cards(builder, deal, randomize_table)
	case .Pbn:
		render_deal_pbn(builder, deal)
	case .Numeric:
		render_deal_numeric(builder, deal)
	}
}

// Write `deal` as a single line: `north|east|south|west`, no trailing newline (the caller decides
// how to separate consecutive deals).
render_deal_line :: proc(builder: ^strings.Builder, deal: Deal) {
	for seat, seat_index in SEAT_OUTPUT_ORDER {
		if seat_index > 0 {
			strings.write_byte(builder, '|')
		}
		write_hand_line(builder, deal[seat])
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

// Write `deal` as four labelled lines, one per seat, e.g.:
//
//	North S:KQT874 H:K74 D:- C:8743
//
// A void suit is shown as '-' so every line has all four suits visible.
render_deal_pretty :: proc(builder: ^strings.Builder, deal: Deal) {
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
			count := write_suit_ranks(builder, deal[seat], suit)
			if count == 0 {
				strings.write_byte(builder, '-') // void
			}
			strings.write_byte(builder, ' ')
		}
		strings.write_byte(builder, '\n')
	}
}

// Write `deal` as a PBN `[Deal]` tag (see the `Pbn` doc on `Output_Format`), no trailing newline.
// The prefix seat is North, so the four hands follow in clockwise N E S W order — exactly
// `SEAT_OUTPUT_ORDER`.
render_deal_pbn :: proc(builder: ^strings.Builder, deal: Deal) {
	strings.write_string(builder, `[Deal "N:`)
	for seat, seat_index in SEAT_OUTPUT_ORDER {
		if seat_index > 0 {
			strings.write_byte(builder, ' ')
		}
		write_hand_pbn(builder, deal[seat])
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

// Write `deal` as deal's compact `numeric` string (see the `Numeric` doc on `Output_Format`), no
// trailing newline: 52 owner-seat digits, the cards walked in S H D C order and, within each suit,
// ranks high-to-low.
render_deal_numeric :: proc(builder: ^strings.Builder, deal: Deal) {
	// Owner seat of each card, indexed by the card's value, so the walk below is a plain lookup.
	owner: [DECK_SIZE]Seat
	for seat in Seat {
		for card in deal[seat] {
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

// Which partnership is vulnerable. Written out rather than carried as an index into a codes table: the
// renderers ask "is N/S vulnerable" far more often than they print the code, and `vul == 1 || vul == 3`
// is the kind of arithmetic that silently rots when a table is reordered.
Vulnerability :: enum {
	None,
	North_South,
	East_West,
	Both,
}

// Is `seat`'s partnership vulnerable under `v`?
vulnerable :: proc "contextless" (v: Vulnerability, seat: Seat) -> bool {
	ns := seat == .North || seat == .South
	switch v {
	case .None:
		return false
	case .Both:
		return true
	case .North_South:
		return ns
	case .East_West:
		return !ns
	}
	return false
}

// The order the table randomisers draw a dealer in — N S E W (the handviewer's own dealer-code order),
// NOT `Seat`'s clockwise N E S W backing order. Kept explicit so a random draw reproduces the same
// deal for a given seed as it did when this was a parallel array of code strings.
@(private = "file")
DEALER_DRAW_ORDER := [SEAT_COUNT]Seat{.North, .South, .East, .West}

// Draw a random table (vulnerability + dealer) from `context.random_generator`, in that order.
@(private = "file")
random_table :: proc() -> (v: Vulnerability, dealer: Seat) {
	v = Vulnerability(rand.int_max(len(Vulnerability)))
	dealer = DEALER_DRAW_ORDER[rand.int_max(SEAT_COUNT)]
	return
}

// Handviewer vulnerability codes (none / NS / EW / both); the dealer code is the seat's own letter.
@(private = "file")
HANDVIEWER_VULNERABILITY_CODES := [Vulnerability]string {
	.None        = "-",
	.North_South = "n",
	.East_West   = "e",
	.Both        = "b",
}

// Write `deal` as a BBO handviewer query string (see the `Handviewer` doc on `Output_Format`):
// `n=s..h..d..c..&s=...&e=...&w=...&a=_&v=..&d=..`, no trailing newline. With `randomize_table` the
// vulnerability and dealer are drawn from `context.random_generator` (matching the Python tool's
// practice-variety randomisation); otherwise they are fixed to `v=-`, `d=n` for deterministic output.
render_deal_handviewer :: proc(builder: ^strings.Builder, deal: Deal, randomize_table := false) {
	for seat in HANDVIEWER_SEAT_ORDER {
		strings.write_rune(builder, handviewer_seat_letter(seat))
		strings.write_byte(builder, '=')
		for suit in SUIT_OUTPUT_ORDER {
			strings.write_rune(builder, handviewer_suit_letter(suit))
			write_suit_ranks(builder, deal[seat], suit)
		}
		strings.write_byte(builder, '&')
	}

	vulnerability := Vulnerability.None
	dealer := Seat.North
	if randomize_table {
		vulnerability, dealer = random_table()
	}
	// Empty auction, then the (fixed or random) vulnerability and dealer.
	strings.write_string(builder, "a=_&v=")
	strings.write_string(builder, HANDVIEWER_VULNERABILITY_CODES[vulnerability])
	strings.write_string(builder, "&d=")
	strings.write_rune(builder, handviewer_seat_letter(dealer))
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

// Write `deal` as a handviewer `<iframe>` div (one deal of an `Html`-format page). The page header
// and footer that surround a run of these are emitted by the generation driver, not here.
// `randomize_table` is forwarded to the handviewer params in the iframe URL.
render_deal_html_iframe :: proc(builder: ^strings.Builder, deal: Deal, randomize_table := false) {
	strings.write_string(builder, HTML_IFRAME_PREFIX)
	render_deal_handviewer(builder, deal, randomize_table)
	strings.write_string(builder, HTML_IFRAME_SUFFIX)
}

// Write `deal` as a text compass diagram (one deal of an `Html_Cards` page): North on top, then a
// middle row of West / centre table / East, then South. Each hand lists its four suits (S H D C) as
// a suit glyph plus ranks, a void shown as an em-dash. The centre table shows dealer and
// vulnerability. `randomize_table` draws those from `context.random_generator` (matching the
// handviewer formats); otherwise they are the fixed defaults. No page chrome here — the carousel
// shell and script are emitted once by the page prologue/epilogue.
// `known` says which seats hold specified cards. The default (all four) is the normal full deal; a
// SUBSET renders a 2-hand (declarer + dummy) deal — the missing seats draw face-down (see
// `write_compass_seat`) and the stats box drops the unknown side. Used by the `pbn_analyse` driver.
render_deal_html_cards :: proc(
	builder: ^strings.Builder,
	deal: Deal,
	randomize_table := false,
	known := bit_set[Seat]{.North, .East, .South, .West},
) {
	full := known == bit_set[Seat]{.North, .East, .South, .West}
	// The seat labels are coloured by vulnerability. A 2-hand deal has no auction context, so it stays
	// neutral: no vulnerability, and NO dealer at all — hence `Maybe(Seat)` rather than an empty string.
	vulnerability := Vulnerability.None
	dealer: Maybe(Seat)
	if randomize_table && full {
		v, d := random_table()
		vulnerability, dealer = v, d
	}
	ns_vulnerable := vulnerable(vulnerability, .North)
	ew_vulnerable := vulnerable(vulnerability, .East)
	is_dealer :: proc(dealer: Maybe(Seat), seat: Seat) -> bool {
		d, has := dealer.?
		return has && d == seat
	}

	// Per-seat summary (hcp + suit-length pattern). Unknown seats summarise a zeroed hand, but the
	// compass never reads those (they render face-down) and the stats box below skips them.
	ds := summarize_deal(deal)

	strings.write_string(builder, `<div class="compass">`)

	// Partnership high-card-point summary, pinned top-right (see the .stats CSS).
	strings.write_string(builder, `<div class="stats">`)
	if full {
		n_hcp, s_hcp := hcp(ds[.North]), hcp(ds[.South])
		e_hcp, w_hcp := hcp(ds[.East]), hcp(ds[.West])
		fmt.sbprintf(builder, `<div>NS: %d + %d = %d HCP</div>`, n_hcp, s_hcp, n_hcp + s_hcp)
		fmt.sbprintf(builder, `<div>EW: %d + %d = %d HCP</div>`, e_hcp, w_hcp, e_hcp + w_hcp)
		// Per-suit E–W split (how N/S's opponents' cards in each suit break), largest-first, with the
		// a-priori probability of that break. Hidden on phones (see the media query).
		strings.write_string(builder, `<div class="splits">`)
		for suit in SUIT_OUTPUT_ORDER {
			write_suit_split(builder, ds, suit)
		}
		strings.write_string(builder, `</div>`)
	} else {
		// 2-hand deal: only the known partnership's combined HCP. The opponents' cards — and hence the
		// E–W splits — are unknown, which is precisely what the combo analyser reasons over.
		side_lbl := "Known"
		ns_side := bit_set[Seat]{.North, .South}
		ew_side := bit_set[Seat]{.East, .West}
		if known == ns_side {
			side_lbl = "N/S"
		} else if known == ew_side {
			side_lbl = "E/W"
		}
		sum := 0
		fmt.sbprintf(builder, `<div>%s: `, side_lbl)
		first := true
		for seat in SEAT_OUTPUT_ORDER {
			if seat not_in known {
				continue
			}
			h := hcp(ds[seat])
			sum += h
			if !first {
				strings.write_string(builder, " + ")
			}
			fmt.sbprintf(builder, "%d", h)
			first = false
		}
		fmt.sbprintf(builder, ` = %d HCP</div>`, sum)
		strings.write_string(builder, `<div class="splits"><div class="split">defenders hidden</div></div>`)
	}
	strings.write_string(builder, `</div>`)

	write_compass_seat(builder, deal, ds, .North, "N", "n", ns_vulnerable, is_dealer(dealer, .North), .North in known)
	strings.write_string(builder, `<div class="mid">`)
	write_compass_seat(builder, deal, ds, .West, "W", "w", ew_vulnerable, is_dealer(dealer, .West), .West in known)
	// Centre marker: the script fills it per slide — the deal number in the 4-hand view, a
	// "Reveal all" button when a single hand is focused. Vulnerability is shown by the seat-pill
	// colours, so it is no longer spelled out here.
	strings.write_string(builder, `<div class="table"></div>`)
	write_compass_seat(builder, deal, ds, .East, "E", "e", ew_vulnerable, is_dealer(dealer, .East), .East in known)
	strings.write_string(builder, `</div>`) // .mid
	write_compass_seat(builder, deal, ds, .South, "S", "s", ns_vulnerable, is_dealer(dealer, .South), .South in known)
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
	deal: Deal,
	ds: Deal_Summary,
	seat: Seat,
	label: string,
	class: string,
	vulnerable: bool,
	dealer: bool,
	is_known := true,
) {
	// A face-down defender on a 2-hand (declarer + dummy) deal: show the position pill but no cards or
	// hand stats (they are unknown — the combo analyser treats them as every possible split).
	if !is_known {
		fmt.sbprintf(
			builder,
			`<div class="seat seat-%s facedown nonvul"><span class="lbl">%s</span><div class="unknown-hand">?</div></div>`,
			class,
			label,
		)
		return
	}
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
		count := write_suit_ranks(builder, deal[seat], suit)
		if count == 0 {
			strings.write_string(builder, "&mdash;") // void
		}
		strings.write_string(builder, `</span>`)
	}

	// This hand's own high-card points, above the shape line, with how likely that HCP total is:
	// the exact chance of it, then the cumulative chance of that many HCP or fewer (from 0).
	h := hcp(ds[seat])
	hp_exact, hp_cum := hcp_probability(h)
	// Percentile band. Above the median we quote "top N%" = the complement of the cumulative
	// (100 - P(<= this HCP)) — the share of hands at least this strong. Below the median that reads
	// backwards ("top 95%"), so flip to "bottom M%" = the cumulative itself. Whichever we show, whole
	// percent when >= 10, else one decimal (so a very weak/strong hand reads "bottom 0.4%", not "0%").
	top := 100 - hp_cum
	is_top := top <= 50
	band_label := "top" if is_top else "bottom"
	band_val := top if is_top else hp_cum
	band_str := fmt.tprintf("%.0f", band_val) if band_val >= 9.5 else fmt.tprintf("%.1f", band_val)
	strings.write_string(builder, `<div class="hcp"`)
	fmt.sbprintf(
		builder,
		` title="%.2f%% of hands hold exactly %d HCP; %.1f%% hold %d or fewer, so this hand sits in about the %s %s%% by strength.">`,
		hp_exact,
		h,
		hp_cum,
		h,
		band_label,
		band_str,
	)
	fmt.sbprintf(builder, "%d HCP", h)
	fmt.sbprintf(builder, ` <span class="prob">%.2f%% &middot; %s %s%%</span>`, hp_exact, band_label, band_str)
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
	0.00363896,
	0.00788442,
	0.0135612,
	0.0246236,
	0.0384544,
	0.0518619,
	0.065541,
	0.0802809,
	0.0889219,
	0.0935623,
	0.0940511,
	0.0894468,
	0.0802687,
	0.0691433,
	0.0569332,
	0.0442368,
	0.0331092,
	0.0236169,
	0.0160508,
	0.0103617,
	0.00643536,
	0.00377867,
	0.00210043,
	0.00111904,
	0.000559034,
	0.000264278,
	0.000116683,
	4.90666e-05,
	1.85677e-05,
	6.67165e-06,
	2.19849e-06,
	6.11319e-07,
	1.71896e-07,
	3.52118e-08,
	7.06127e-09,
	9.82656e-10,
	9.44862e-11,
	6.29908e-12,
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

// The Unicode card-suit glyph, used by the card diagram (hearts/diamonds are coloured red via CSS) and
// by consumers labelling per-suit output (e.g. the dd package's OPC breakdown tooltip).
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

// The header emitted once before the deals of an `Html`-format (BBO handviewer) run (everything up to the deal divs).
@(private = "file")
HTML_HANDVIEWER_PAGE_HEADER :: `<!DOCTYPE html>
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
HTML_HANDVIEWER_PAGE_FOOTER :: `</body>
`

// The header for an `Html_Cards` run: page chrome, the carousel CSS, the toolbar, and the open
// viewport/track that the rendered compass diagrams are written into. The matching footer closes the
// track and carries the script. Both live in `.html.tmpl` files beside this one and are `#load`ed at
// COMPILE time — the constant is the file's bytes, so there is no runtime file I/O and the binary
// stays self-contained, while the editor sees real HTML/CSS/JS instead of one long Odin literal.
@(private = "file")
HTML_CARDS_PAGE_HEADER :: #load("html_cards_header.html.tmpl", string)

// The footer for an `Html_Cards` run: closes the track/viewport, then the script that turns the
// flat sequence of compass (and par) elements into slides and drives the carousel.
@(private = "file")
HTML_CARDS_PAGE_FOOTER :: #load("html_cards_footer.html.tmpl", string)

// Write the once-per-run prologue for `format`. Only the HTML formats have one (the page header);
// every other format opens with nothing. `page_title` (empty -> "Practice Deals") fills both the
// document `<title>` and the on-page `<h1>` via the `{{TITLE}}` token baked into the header literals.
render_page_prologue :: proc(builder: ^strings.Builder, format: Output_Format, page_title := "") {
	header: string
	#partial switch format {
	case .Html_Handviewer:
		header = HTML_HANDVIEWER_PAGE_HEADER
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
		strings.write_string(builder, HTML_HANDVIEWER_PAGE_FOOTER)
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
