package norn

/*
	summary.odin — the hand representation evaluation runs on, and the evaluators over it.

	A `Hand` is 13 unordered cards; answering "how long is this suit / does it hold the king /
	what's its shape" by rescanning all 13 on every query is wasteful when a predicate fires dozens
	of such queries and reject sampling runs that predicate over millions of deals.

	A `Hand_Summary` is the per-suit index almost every query actually wants: four `Rank_Set`s, one
	per suit, holding the ranks the hand has in that suit. A `Rank_Set` is a `bit_set[Rank; u16]` — the
	same bit-per-rank u16 a hand-rolled mask would be, so the hot queries stay popcount / AND / bit-test,
	but typed, so a length or a point count can't be passed as a holding:

	  suit length   -> card(ranks)
	  holds(r)      -> r in ranks
	  top_count(n)  -> card(ranks & TOP_N)
	  hcp/controls  -> a few membership tests
	  pattern       -> 4 popcounts (+ sort of 4)

	The summary is a LOSSLESS re-encoding of a hand for evaluation — it drops only card ordering
	(irrelevant) and can't represent duplicates (impossible in bridge) — so every evaluator a
	predicate needs lives here, over `Hand_Summary`. `Hand` survives only where the actual cards
	matter: predeal/SmartStack construction and rendering. The generation core builds one
	`Deal_Summary` per deal and hands it to the `Predicate` (see generate.odin), so a condition
	pays the 13-op build once per deal, not once per query.

	These evaluators mirror the vocabulary of the `deal` engine's Tcl library (`hcp`, `controls`,
	suit lengths, `pattern`/`shape`, `balanced`, the `TopN`/`Top5Q` honour vectors, `losers`,
	`offense`, `defense`, `OP`, `dhcp`, `newLTC`) so the ported predicates read almost line-for-line.
	`losers` and `offense` reproduce deal.exe to the digit (verified by probing it over every honour
	combination); the rest are ported straight from deal's evaluators/utility/features libraries.
*/

// Per-suit rank sets. `suits[suit]` holds exactly the ranks the hand has in that suit.
Hand_Summary :: struct {
	suits: [Suit]Rank_Set,
}

// A whole deal's worth of summaries, indexed by seat (parallel to `Deal`).
Deal_Summary :: [Seat]Hand_Summary

// The top ranks (ace downward), as sets of the top n. `TOP_RANKS[2]` is {A, K}; index 0..7 runs through
// A K Q J T 9 8. Matches the `deal` `TopN` honour vectors up to Top7.
@(private = "file")
TOP_RANKS := [8]Rank_Set {
	{},
	{.Ace},
	{.Ace, .King},
	{.Ace, .King, .Queen},
	{.Ace, .King, .Queen, .Jack},
	{.Ace, .King, .Queen, .Jack, .Ten},
	{.Ace, .King, .Queen, .Jack, .Ten, .Nine},
	{.Ace, .King, .Queen, .Jack, .Ten, .Nine, .Eight},
}

// `baselose` table, indexed by suit length 0..13: the crude number of losers a suit of that length
// has before honours are considered. `offense` uses it to pick how hard to look at the top cards.
// (deal: `set Losers($len)` in `lib/utility.tcl` / `lib/evaluators.tcl`.)
@(private = "file")
BASE_LOSERS := [RANK_COUNT + 1]int{0, 1, 2, 3, 4, 4, 3, 3, 2, 2, 2, 1, 1, 0}

// Per-suit dhcp weight vectors, indexed by the suit's length bucket 0/1/2/3+ (deal's
// `defvector dhcp0/1/2/3`). Each row weights the honours A K Q J from the top down. Honours in short
// suits are written down: a singleton king is worth 2 not 3, a singleton queen/jack 0; a doubleton
// queen/jack only 1. A suit of three or more uses the plain 4-3-2-1 of `hcp`.
@(private = "file")
DHCP_WEIGHTS := [4][4]int {
	{0, 0, 0, 0}, // void
	{4, 2, 0, 0}, // singleton
	{4, 3, 1, 1}, // doubleton
	{4, 3, 2, 1}, // three or more (== hcp)
}

// Build the bitmask index for a hand (13 ops, once).
summarize :: proc(hand: Hand) -> Hand_Summary {
	s: Hand_Summary
	for card in hand {
		s.suits[card_suit(card)] += {card_rank(card)}
	}
	return s
}

// Build summaries for all four seats of a deal.
summarize_deal :: proc(deal: Deal) -> Deal_Summary {
	ds: Deal_Summary
	for seat in Seat {
		ds[seat] = summarize(deal[seat])
	}
	return ds
}

// --- Counts and lookups. ---

// The ranks the hand holds in `suit`. Sugar for the field, and the name to reach for in consumer code —
// `suit_ranks(s, .Spades)` says what it is where `s.suits[.Spades]` says where it is stored.
suit_ranks :: #force_inline proc "contextless" (s: Hand_Summary, suit: Suit) -> Rank_Set {
	return s.suits[suit]
}

// The raw bit-per-rank `u16` for `suit` — the escape hatch for code with its own mask conventions (the
// combo analyser's single-suit solvers, a double-dummy solver's encoding). Prefer `suit_ranks` in new
// code; this exists so those callers say what they are doing instead of transmuting in place.
suit_mask :: #force_inline proc "contextless" (s: Hand_Summary, suit: Suit) -> u16 {
	return rank_mask(s.suits[suit])
}

// Number of cards held in `suit` (0..13).
suit_length :: proc(s: Hand_Summary, suit: Suit) -> int {
	return card(s.suits[suit])
}

// Named per-suit length shortcuts, mirroring deal's `spades $hand` / `hearts $hand` vocabulary.
spade_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Spades)}
heart_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Hearts)}
diamond_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Diamonds)}
club_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Clubs)}

// Does the hand hold this exact card?
holds :: proc(s: Hand_Summary, suit: Suit, rank: Rank) -> bool {
	return rank in s.suits[suit]
}

// High-card points for the whole hand: Ace=4, King=3, Queen=2, Jack=1.
hcp :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if .Ace in m {total += 4}
		if .King in m {total += 3}
		if .Queen in m {total += 2}
		if .Jack in m {total += 1}
	}
	return total
}

// Control count for the whole hand: Ace=2, King=1.
controls :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if .Ace in m {total += 2}
		if .King in m {total += 1}
	}
	return total
}

// How many of the top `n` ranks the hand holds in `suit` (deal's `TopN` honour vectors). `n` is
// 0..7 (A K Q J T 9 8).
top_count :: proc(s: Hand_Summary, suit: Suit, n: int) -> int {
	return card(s.suits[suit] & TOP_RANKS[n])
}

// Weighted top-honour count for `suit`: ace, king and queen score 2 each; jack and ten score 1
// each (deal `defvector Top5Q 2 2 2 1 1`). A solid AKQ is 6; AKQJT is 8.
top5q :: proc(s: Hand_Summary, suit: Suit) -> int {
	m := s.suits[suit]
	high := Rank_Set{.Ace, .King, .Queen}
	low := Rank_Set{.Jack, .Ten}
	return 2 * card(m & high) + card(m & low)
}

// Sum of `weights` over the top ranks held in `suit`, ace downward: `weights[0]` for the ace,
// `weights[1]` for the king, … through A K Q J T 9 8. Ranks past the end of `weights` score 0.
@(private = "file")
suit_top_weighted :: proc(s: Hand_Summary, suit: Suit, weights: []int) -> int {
	ranks := [7]Rank{.Ace, .King, .Queen, .Jack, .Ten, .Nine, .Eight}
	sum := 0
	for weight, i in weights {
		if holds(s, suit, ranks[i]) {
			sum += weight
		}
	}
	return sum
}

// --- Shape. ---

// The hand's shape: suit lengths in S H D C order (deal's `[hand shape]`).
shape :: proc(s: Hand_Summary) -> [SUIT_COUNT]int {
	return [SUIT_COUNT]int {
		suit_length(s, .Spades),
		suit_length(s, .Hearts),
		suit_length(s, .Diamonds),
		suit_length(s, .Clubs),
	}
}

// The hand's pattern: the four suit lengths sorted high-to-low and suit-agnostic (deal's
// `[hand pattern]`), e.g. {5, 4, 2, 2}.
pattern :: proc(s: Hand_Summary) -> [SUIT_COUNT]int {
	lengths := shape(s)
	// Selection sort, descending — only four elements.
	for i in 0 ..< SUIT_COUNT {
		largest := i
		for j in i + 1 ..< SUIT_COUNT {
			if lengths[j] > lengths[largest] {
				largest = j
			}
		}
		lengths[i], lengths[largest] = lengths[largest], lengths[i]
	}
	return lengths
}

// Is the hand a "5CM_nt" shape: exactly 4-3-3-3, 4-4-3-2 or 5-3-3-2 (the 5 may be a major)? deal's
// `5CM_nt` shape test with the hcp range stripped out (callers pair it with their own hcp band).
is_nt5cM_shape :: proc(s: Hand_Summary) -> bool {
	has_four := false
	has_five := false
	for suit in Suit {
		length := suit_length(s, suit)
		if length < 2 || length > 5 {
			return false
		}
		if length == 4 {has_four = true}
		if length == 5 {has_five = true}
	}
	return !(has_four && has_five)
}

// Is the hand balanced? deal's definition: no 5-card major and the sum of squared suit lengths is at
// most 47 (admits 4-3-3-3, 4-4-3-2 and minor 5-3-3-2).
is_balanced :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	if sp >= 5 || h >= 5 {
		return false
	}
	return sp * sp + h * h + d * d + c * c <= 47
}

// Is the hand semi-balanced? deal's definition: no suit shorter than a doubleton, no major longer
// than 5, no minor longer than 6.
is_semibalanced :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	return sp >= 2 && h >= 2 && d >= 2 && c >= 2 && sp <= 5 && h <= 5 && d <= 6 && c <= 6
}

// Is the hand a notrump opening of `min`..`max` hcp: balanced AND in the hcp range (deal's
// `nt $hand min max`).
is_nt :: proc(s: Hand_Summary, min, max: int) -> bool {
	if !is_balanced(s) {
		return false
	}
	points := hcp(s)
	return points >= min && points <= max
}

// The four "longest-suit" shape classes (deal's `shapeclass spade_shape`/…): they PARTITION all
// hands — every hand matches exactly one. A MAJOR class requires a genuine 5+ suit; the two MINOR
// classes pick up the rest (including all flat hands). See the original doc in git history for the
// tie-break rationale.

// `is_spade_shape`: spades a 5+ suit, at least as long as hearts and the minors (spades win ties).
is_spade_shape :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	return sp >= 5 && sp >= h && d <= sp && c <= sp
}

// `is_heart_shape`: hearts a 5+ suit, strictly longer than spades and at least as long as the minors.
is_heart_shape :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	return h >= 5 && sp < h && d <= h && c <= h
}

// `is_diamond_shape`: diamonds the long minor, beating both majors and clubs (a clubs tie counts as
// diamonds only when both are 5+).
is_diamond_shape :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	return (sp < 5 || d > sp) && (h < 5 || d > h) && (d > c || (d == c && d >= 5))
}

// `is_club_shape`: clubs the long minor, beating both majors and diamonds (a diamonds tie counts as
// clubs only when both are under 5).
is_club_shape :: proc(s: Hand_Summary) -> bool {
	sp := suit_length(s, .Spades)
	h := suit_length(s, .Hearts)
	d := suit_length(s, .Diamonds)
	c := suit_length(s, .Clubs)
	return (sp < 5 || c > sp) && (h < 5 || c > h) && (d < c || (d == c && c < 5))
}

// --- Trick estimators (loser/offense/defense family). ---

// Losing Trick Count for the whole hand, matching deal's `losers` builtin EXACTLY — HALF-loser
// units (every value doubled), plus the queen refinement: a held queen only fully covers its slot
// when "backed" by another honour (A/K/J/T) in the suit; an unbacked queen covers only half.
losers :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		length := suit_length(s, suit)
		if length == 0 {
			continue
		}
		ace := holds(s, suit, .Ace)
		king := holds(s, suit, .King)
		if !ace {
			total += 2
		}
		if length >= 2 && !king {
			total += 2
		}
		if length >= 3 {
			if !holds(s, suit, .Queen) {
				total += 2
			} else if !(ace || king || holds(s, suit, .Jack) || holds(s, suit, .Ten)) {
				total += 1
			}
		}
	}
	return total
}

// Estimated offensive tricks from `suit` (deal's `offense`, verified to the digit). Start from the
// suit length and dock losers by which top honours are missing; a solid suit returns its full
// length, a ragged one several fewer.
offense :: proc(s: Hand_Summary, suit: Suit) -> int {
	length := suit_length(s, suit)
	a := holds(s, suit, .Ace)
	k := holds(s, suit, .King)
	q := holds(s, suit, .Queen)
	j := holds(s, suit, .Jack)
	t := holds(s, suit, .Ten)
	n9 := holds(s, suit, .Nine)
	n8 := holds(s, suit, .Eight)
	ai := int(a); ki := int(k); qi := int(q); ji := int(j); ti := int(t); n9i := int(n9); n8i := int(n8)

	switch BASE_LOSERS[length] {
	case 0:
		return length
	case 1:
		return length - 1 + ai
	case 2:
		if a && k {return length}
		if a || (k && q) {return length - 1}
		return length - 2
	case 3:
		if a && k && q {return length}
		if (a && k) || ((a || k) && q && j) {return length - 1}
		if a || (k && q) {return length - 2}
		if (q || k) && j && (t || n9) {return length - 2}
		return length - 3
	case:
		// baselose == 4 (a 4- or 5-card suit).
		if a && k && q && (j || t) {return length}
		if 3 * (ai + ki + qi + ji) + ti + n9i >= 10 {return length - 1}
		if 4 * (ai + ki + qi + ji) + ti + n9i + n8i >= 10 {return length - 2}
		if 20 * ai + 12 * ki + 12 * qi + 6 * ji + 2 * ti + n9i + n8i > 20 {return length - 3}
		return length - 4
	}
}

// Estimated DEFENSIVE tricks from `suit`, in HALF-units (like `losers`), matching deal's `defense`
// holdingProc. Honours that win tricks on defence are devalued in short suits.
defense :: proc(s: Hand_Summary, suit: Suit) -> int {
	length := suit_length(s, suit)
	a := holds(s, suit, .Ace)
	k := holds(s, suit, .King)
	q := holds(s, suit, .Queen)
	j := holds(s, suit, .Jack)

	half := 0
	if a {half += 2}
	if k && length < 7 {half += 2}
	if k && length == 7 {half += 1}
	if q && length < 6 {
		if a || k {
			half += 2
		} else {
			half += 1
		}
	}
	if q && length == 6 && (a || k) {half += 1}
	if length <= 4 && a && k && !q && j {half += 1}
	return half
}

// Offensive potential of the whole hand (deal's `OP`): per suit `offense - defense` (since `defense`
// here is already deal's `2*defense`), summed. High for shapely offensive hands, low/negative for
// flat defensive ones.
op :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		total += offense(s, suit) - defense(s, suit)
	}
	return total
}

// Distribution-adjusted high-card points for the whole hand (deal's `dhcp`): like `hcp`, but honours
// in short suits count for less (see `DHCP_WEIGHTS`).
dhcp :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		bucket := min(suit_length(s, suit), 3)
		total += suit_top_weighted(s, suit, DHCP_WEIGHTS[bucket][:])
	}
	return total
}

// "New" Losing Trick Count for the whole hand, in HALF-units (deal's `newLTC`): counts only missing
// A/K/Q cover cards, no queen-backing refinement — missing ace 3, missing king (len>=2) 2, missing
// queen (len>=3) 1.
new_ltc :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		length := suit_length(s, suit)
		if length == 0 {
			continue
		}
		if !holds(s, suit, .Ace) {total += 3}
		if length >= 2 && !holds(s, suit, .King) {total += 2}
		if length >= 3 && !holds(s, suit, .Queen) {total += 1}
	}
	return total
}

// --- Optimal Point Count (OPC). ---
//
// A finer-grained hand valuation than plain `hcp`, ported from the reference `optimal_point_count.py`
// (docs/bridge). Where Milton hcp gives every ace 4 and every queen 2, OPC values each honour by its
// company (a queen next to a picture is worth more than an isolated one), rewards concentrated and
// long suits, and applies whole-hand corrections (no queens, four kings, distribution). All values
// are exact multiples of 0.5, so `f32` holds them without rounding drift; callers that display them
// should format to one decimal place.
//
// The single-hand valuation splits into three independent components — Honour (H), Length (L) and
// Distribution (D) points — combined by `opc_points` into the four "starting point" totals a hand
// can present, over the two axes that change the count:
//   * opening vs non-opening: an aceless hand is docked a point only when valued as an opener.
//   * suit vs notrump:        shortage (singleton/void) points that help in a suit contract are a
//                             liability at notrump, so the D component carries a separate NT total.
// The partner-dependent adjustments the Python tool also reports (fit points, wastage opposite
// shortage, weak-honour upgrades) are NOT computed here — they need the partnership context a single
// `Hand_Summary` doesn't have.

// The picture honours — A K Q J. The Ten is an honour but not a picture, and several OPC rules turn on
// exactly that distinction.
@(private = "file")
PICTURES :: Rank_Set{.Ace, .King, .Queen, .Jack}

// Milton hcp of a single suit holding (Ace 4, King 3, Queen 2, Jack 1; Ten 0). Used by the OPC length
// component to tell a "good" (K+ / QJ) long suit from a ragged one.
@(private = "file")
milton_hcp :: proc(m: Rank_Set) -> int {
	total := 0
	if .Ace in m {total += 4}
	if .King in m {total += 3}
	if .Queen in m {total += 2}
	if .Jack in m {total += 1}
	return total
}

// OPC Honour points. Two totals that differ only by the aceless opening penalty (see the section
// header); every other adjustment is common to both.
Honour_Points :: struct {
	opening:     f32, // includes the -1 aceless dock when it applies
	non_opening: f32,
}

// OPC Distribution points. `suit` counts shortages as assets; `nt` re-books them as liabilities.
Distribution_Points :: struct {
	suit: f32,
	nt:   f32,
}

// The four OPC starting-point totals of a hand, plus the H/L/D components they are built from.
Opc_Points :: struct {
	opening_suit:     f32,
	opening_nt:       f32,
	non_opening_suit: f32,
	non_opening_nt:   f32,
	honour:           Honour_Points,
	length:           f32,
	distribution:     Distribution_Points,
}

// OPC Honour points for the whole hand: honours valued by their company within each suit, then
// whole-hand corrections for missing/plentiful queens and kings and (opening only) a missing ace.
honour_points :: proc(s: Hand_Summary) -> Honour_Points {
	total: f32 = 0

	for suit in Suit {
		m := s.suits[suit]
		length := card(m)
		if length == 0 {
			continue
		}

		a := .Ace in m
		k := .King in m
		q := .Queen in m
		j := .Jack in m
		ten := .Ten in m
		// Picture honours (A/K/Q/J — the Ten is not a picture) and "small" cards (Nine down to Two).
		pics := card(m & PICTURES)
		xs := length - card(m & (PICTURES + {.Ten}))

		if a {total += 4.5}
		if k {total += 3.0}
		if q {
			// A queen "accompanied" by another picture (A/K/J) pulls its full weight; isolated it is
			// downvalued.
			if m & {.Ace, .King, .Jack} != {} {
				total += 2.0
			} else {
				total += 1.5
			}
		}
		if j {
			if m & {.Ace, .King, .Queen} != {} {
				total += 1.0
			} else {
				total += 0.5
			}
		}
		if ten {
			// The Ten is valued once, by the nearest honour that makes it pull weight.
			switch {
			case j && pics == 1 && xs > 0:
				total += 1.5 // JT with small cards: upvalues the whole T+J combination
			case j && pics == 1 && xs == 0:
				total += 1.0 // JT bare doubleton
			case j:
				total += 1.0 // T+J alongside other honour(s)
			case q:
				if pics == 1 && xs == 0 {
					total += 0.5 // QT bare doubleton
				} else {
					total += 1.0 // T+Q combo
				}
			case k:
				total += 0.5 // T+K, no Q or J
			}
		}

		// Bare picture honours are fragile: a singleton A/K/Q (not a jack) is docked.
		if length == 1 && (a || k || q) {
			total -= 1.0
		}
		// Qx / Jx doubletons (the honour plus a single small card, nothing else) are docked.
		if q && pics == 1 && !ten && xs == 1 {
			total -= 0.5
		}
		if j && pics == 1 && !ten && xs == 1 {
			total -= 0.5
		}
		// Two touching/near-touching honours with no length behind them (AQ/AK/KQ/QJ doubleton) are
		// docked — their combined power needs a third card to cash.
		if length == 2 && xs == 0 {
			if (a && q) || (a && k) || (k && q) || (q && j) {
				total -= 1.0
			}
		}
		// Concentrated strength in a long suit is worth extra.
		if pics >= 3 {
			if length == 5 {
				total += 1.0
			} else if length >= 6 {
				total += 2.0
			}
		}
	}

	// Whole-hand honour corrections.
	kings := 0
	queens := 0
	has_ace := false
	for suit in Suit {
		m := s.suits[suit]
		if .King in m {kings += 1}
		if .Queen in m {queens += 1}
		if .Ace in m {has_ace = true}
	}
	no_kings := kings == 0
	no_queens := queens == 0

	if no_queens {total -= 1.0}
	if no_kings {total -= 1.0}
	if kings == 3 {total += 1.0}
	if kings == 4 {total += 2.0}
	if queens == 4 {total += 1.0}

	non_opening := total
	opening := total
	// An aceless hand is a poor opener — but not docked twice: if it is already stripped of kings AND
	// queens the missing-king/queen penalties have covered it.
	if !has_ace && !(no_kings && no_queens) {
		opening -= 1.0
	}

	return Honour_Points{opening = opening, non_opening = non_opening}
}

// OPC Length points for the whole hand: a good (K+ / QJ) five-card suit is worth 1, a good six-card
// suit 2, a poor six-card suit 1, and every card beyond the sixth another 2.
length_points :: proc(s: Hand_Summary) -> f32 {
	total: f32 = 0
	for suit in Suit {
		m := s.suits[suit]
		length := card(m)
		good := milton_hcp(m) >= 3
		if length == 5 && good {total += 1.0}
		if length >= 6 && good {total += 2.0}
		if length >= 6 && !good {total += 1.0}
		if length >= 7 {total += f32(2 * (length - 6))}
	}
	return total
}

// OPC Distribution points for the whole hand. The `suit` total rewards shortage (a singleton is 2, a
// void 4, two doubletons a bonus 1) and docks the flat 4-3-3-3; the `nt` total then subtracts those
// shortage assets back off, since they do not help at notrump.
distribution_points :: proc(s: Hand_Summary) -> Distribution_Points {
	tripletons := 0
	doubletons := 0
	singletons := 0
	voids := 0
	for suit in Suit {
		switch suit_length(s, suit) {
		case 0:
			voids += 1
		case 1:
			singletons += 1
		case 2:
			doubletons += 1
		case 3:
			tripletons += 1
		}
	}

	total: f32 = 0
	nt_adjust: f32 = 0

	if tripletons == 3 {total -= 1.0} 	// 4-3-3-3 flat
	if doubletons == 2 {total += 1.0}
	if singletons > 0 {
		total += f32(singletons) * 2.0
		nt_adjust += -f32(singletons) // shortage value removed at NT
		nt_adjust += -1.0 // and a flat penalty for declaring NT with a singleton
	}
	if voids > 0 {
		total += f32(voids) * 4.0
		nt_adjust += -2.0 // shortage value removed at NT
		nt_adjust += -1.0 // and a flat penalty for declaring NT with a void
	}

	return Distribution_Points{suit = total, nt = total + nt_adjust}
}

// The full OPC valuation of a hand: the H/L/D components and the four starting-point totals they
// combine into (opening/non-opening x suit/notrump). See the section header for the axes.
opc_points :: proc(s: Hand_Summary) -> Opc_Points {
	h := honour_points(s)
	l := length_points(s)
	d := distribution_points(s)
	return Opc_Points {
		honour = h,
		length = l,
		distribution = d,
		opening_suit = l + h.opening + d.suit,
		opening_nt = l + h.opening + d.nt,
		non_opening_suit = l + h.non_opening + d.suit,
		non_opening_nt = l + h.non_opening + d.nt,
	}
}

// --- Partnership combined OPC: per-suit adjustment primitives ---
//
// `opc_points` values ONE hand; a partnership is not the sum of two such counts — honours face
// shortness, shortness faces length, an eight-card fit adds tricks, weak honours firm up in a fit. The
// small pure functions below are the independently-testable combining building blocks the reference
// optimal_point_count.py describes as its partner-dependent adjustments (`with_partners_long_suit`,
// `with_partners_shortage`, `fitting_weak_honours`, the "Fit points" note). A later `combined_opc`
// composes them over two hands. Each takes raw per-suit rank masks, so it can be unit-tested alone.

// Why a single combined-OPC adjustment fired — the label the reference render_summary attaches to each
// entry. `combined_opc_breakdown` tags every per-suit entry with one of these so a consumer can print
// "misfit (♠): singleton opposite long" rather than only a summed number. `opc_reason_text` renders the
// human phrase.
Opc_Reason :: enum {
	None,
	Fit, // 8/9/10-card fit (the card count is read off the entry's value: 1→8, 2→9, 3→10+)
	Misfit_Void, // -3: void opposite partner's 5+ suit
	Misfit_Singleton, // -2: singleton opposite long
	Misfit_Xx, // -1: two small opposite long
	Semi_Fit, // +1: Kx/Qx/Jx/JT working doubleton opposite long
	Wasted_Void, // -3: K/Q/J opposite partner's void
	Wasted_Singleton, // -2: K/Q/J opposite partner's singleton
	Freed_Void, // +3: no wasted honour opposite void
	Freed_Singleton, // +2: no wasted honour opposite singleton
	Freed_Ace_Singleton, // +1: bare ace opposite singleton
	Weak_Honour_Fit, // +1: weak picture holding firms up inside an 8+ fit
	Per_Suit_Mirror, // -1: same-suit equal short length (duplicated shortness)
	Whole_Hand_Mirror, // -2: identical patterns with a long suit
	Ruff_Support, // responder's 2-4 trump support ruffing its shortest side suit
	Ruff_Long_Trump, // responder's 5+ trump length counting shortage in full
}

// The reference render_summary phrase for a reason (no suit / sign — the caller prints those).
opc_reason_text :: proc(r: Opc_Reason) -> string {
	switch r {
	case .None:
		return ""
	case .Fit:
		return "fit"
	case .Misfit_Void:
		return "void opp long"
	case .Misfit_Singleton:
		return "singleton opp long"
	case .Misfit_Xx:
		return "xx opp long"
	case .Semi_Fit:
		return "Kx/Qx/Jx/JT opp long"
	case .Wasted_Void:
		return "honour opp void"
	case .Wasted_Singleton:
		return "honour opp singleton"
	case .Freed_Void:
		return "no wasted honour opp void"
	case .Freed_Singleton:
		return "no wasted honour opp singleton"
	case .Freed_Ace_Singleton:
		return "bare ace opp singleton"
	case .Weak_Honour_Fit:
		return "weak honour in fit"
	case .Per_Suit_Mirror:
		return "mirror suit"
	case .Whole_Hand_Mirror:
		return "mirror hand"
	case .Ruff_Support:
		return "ruff, support"
	case .Ruff_Long_Trump:
		return "ruff, long trump"
	}
	return ""
}

// Fit points for a suit's COMBINED partnership length: an eight-card fit is worth 1, a nine 2, a
// ten-or-longer 3 — at suit and notrump alike. Shorter than eight scores nothing. This is per SUIT:
// the composition sums it over all four, so a double fit (two 8+ suits) rightly counts both.
@(private)
opc_fit_points :: proc(combined_length: int) -> f32 {
	switch {
	case combined_length >= 10:
		return 3.0
	case combined_length == 9:
		return 2.0
	case combined_length == 8:
		return 1.0
	}
	return 0.0
}

// This hand's holding `m` (length `l`) OPPOSITE partner's five-plus card suit: a shortage is a misfit
// (void -3, singleton -2, two small cards -1) while a working doubleton — Kx/Qx/Jx or JT — half-fits
// for +1. Three-plus cards, or a doubleton that is neither (Ax, QJ, KQ, …), is neutral. Caller applies
// this only when PARTNER is long (>=5) in the suit. (opc `with_partners_long_suit`.)
@(private)
opc_opposite_long_suit :: proc(m: Rank_Set, l: int) -> f32 {
	v, _ := opc_opposite_long_suit_detail(m, l)
	return v
}

// As opc_opposite_long_suit, also returning WHICH case fired (for the breakdown's labelled entry).
@(private)
opc_opposite_long_suit_detail :: proc(m: Rank_Set, l: int) -> (f32, Opc_Reason) {
	switch l {
	case 0:
		return -3.0, .Misfit_Void
	case 1:
		return -2.0, .Misfit_Singleton
	case 2:
		if m & (PICTURES + {.Ten}) == {} {
			return -1.0, .Misfit_Xx // xx: two small cards
		}
		// Exactly one of K/Q/J plus a small card (no ace, no ten) is Kx/Qx/Jx; a bare JT also half-fits.
		honours := card(m & {.King, .Queen, .Jack})
		if honours == 1 && m & {.Ace, .Ten} == {} {
			return 1.0, .Semi_Fit // Kx / Qx / Jx
		}
		if .Jack in m && .Ten in m {
			return 1.0, .Semi_Fit // JT
		}
	}
	return 0.0, .None
}

// This hand's honours in `m` OPPOSITE partner's shortage in the SAME suit (`partner_length` 0 = void,
// 1 = singleton): a King/Queen/Jack is largely wasted (void -3, singleton -2); holding none, the hand
// has nothing to waste — a plus (void +3, singleton +2) — and an isolated Ace a small plus opposite a
// singleton only (+1). Caller applies this only when PARTNER is short (<=1) in the suit. (opc
// `with_partners_shortage`.)
@(private)
opc_honour_opposite_shortage :: proc(m: Rank_Set, partner_length: int) -> f32 {
	v, _ := opc_honour_opposite_shortage_detail(m, partner_length)
	return v
}

// As opc_honour_opposite_shortage, also returning WHICH case fired (for the breakdown's labelled entry).
@(private)
opc_honour_opposite_shortage_detail :: proc(m: Rank_Set, partner_length: int) -> (f32, Opc_Reason) {
	void := partner_length == 0
	if m & {.King, .Queen, .Jack} != {} {
		if void {return -3.0, .Wasted_Void}
		return -2.0, .Wasted_Singleton
	}
	if .Ace not_in m {
		if void {return 3.0, .Freed_Void}
		return 2.0, .Freed_Singleton
	}
	if void {return 0.0, .None} 	// nothing to free opposite a void with a bare ace
	return 1.0, .Freed_Ace_Singleton
}

// A weak but real honour holding `m` firms up inside an eight-plus fit: under four Milton points, not
// the full QJT (which already pulls its weight), yet holding at least one picture honour → +1. Caller
// applies this per hand only in a suit that is an eight-plus combined fit. (opc `fitting_weak_honours`.)
@(private)
opc_weak_honour_fit_upgrade :: proc(m: Rank_Set) -> f32 {
	if milton_hcp(m) >= 4 {
		return 0.0
	}
	if (Rank_Set{.Queen, .Jack, .Ten}) <= m {
		return 0.0 // QJT: excluded — essentially four points already
	}
	if m & PICTURES != {} {
		return 1.0
	}
	return 0.0
}

// Is the hand a flat 4-3-3-3 (exactly three tripletons)?
@(private = "file")
is_4333 :: proc(s: Hand_Summary) -> bool {
	threes := 0
	for suit in Suit {
		if suit_length(s, suit) == 3 {
			threes += 1
		}
	}
	return threes == 3
}

// A hand in its partnership ROLE. Most OPC adjustments are symmetric — a misfit is a misfit whichever
// hand is short — but three are NOT: the responder's base is capped where the opener's is not, and the
// ruffing value belongs to the responder alone (the opener's shortage is already inside its opening
// base). Those procs take `Responder`, so the opener cannot reach them by accident: the roles are
// decided in ONE place (`combined_opc_breakdown`, by strength) and the type carries that decision.
// Cast to `Hand_Summary` for the symmetric evaluators.
@(private)
Opener :: distinct Hand_Summary
@(private)
Responder :: distinct Hand_Summary

// The base OPC a RESPONDER/advancer brings to the partnership total — always the non-opening honour
// count (a responder never gets the opener's aceless dock), but for a SUIT contract its Length points
// are capped at 2 and its Distribution points shrink to only the -1 flat 4-3-3-3 penalty: a responder's
// shortage is worth nothing until a trump fit turns it into ruffing value (that arrives later as
// distribution-fit points), and its extra length is only worth counting once a fit is known. Declaring
// NOTRUMP lifts both limits — length runs and the NT distribution (shortage already a liability) apply
// in full — so the NT base is just the ordinary non-opening NT total. (opc render_summary: "Responder/
// Advancer only includes max 2 Length points and the -1 4333 Distribution points, UNLESS ... NT".)
@(private)
opc_responder_base :: proc(r: Responder, is_nt: bool) -> f32 {
	s := Hand_Summary(r)
	o := opc_points(s)
	if is_nt {
		return o.non_opening_nt
	}
	length := o.length
	if length > 2.0 {
		length = 2.0
	}
	flat: f32 = -1.0 if is_4333(s) else 0.0
	return o.honour.non_opening + length + flat
}

// Does the hand hold a five-plus card suit?
@(private = "file")
has_five_plus :: proc(s: Hand_Summary) -> bool {
	for suit in Suit {
		if suit_length(s, suit) >= 5 {
			return true
		}
	}
	return false
}

// Whole-hand mirror penalty: two hands with the SAME LENGTH IN EVERY SUIT (identical distributions,
// e.g. both 5=3=3=2 with the spades opposite the spades) duplicate each other's shape exactly — no
// shortness can ruff, no length is complementary — so the partnership is worth -2 beyond the per-suit
// mirrors. Positional (per-suit) equality, NOT merely the same sorted pattern: two 5-3-3-2 hands whose
// five-card suits differ are not a whole-hand mirror. Gated, like the reference, on a 5+ suit somewhere
// ("mirror hand when partner has a long suit"). Stacks ON TOP of the per-suit mirrors (a full mirror is
// necessarily four mirror suits too — the -2 is the extra whole-hand tax).
@(private)
opc_mirror_penalty :: proc(a, b: Hand_Summary) -> f32 {
	if !has_five_plus(a) && !has_five_plus(b) {
		return 0.0
	}
	for suit in Suit {
		if suit_length(a, suit) != suit_length(b, suit) {
			return 0.0 // any suit of differing length -> not a whole-hand mirror
		}
	}
	return -2.0
}

// Per-suit mirror penalty (opc `with_partners_long_suit`: "per mirror suit when partner has a long
// suit"): a "mirror suit" is one where BOTH hands hold the SAME length and that length is NON-FIT
// (combined < 8, i.e. an equal length of 3 or fewer) — the shape is duplicated with no complementary
// value (short mirrors can't ruff; a mirrored 3-3 wastes the third card). Charge -1 per such suit. The
// combined-<8 bound means a mirror suit is never a fit, so this never fights the fit-points term (an
// equal 4-4+ is a fit, scored there, not a mirror). Gated, like the whole-hand mirror, on a 5+ suit
// existing somewhere; with no long suit the mirrored shape is not a liability. This is the COMMON case
// (a full whole-hand mirror is rare); it stacks with the whole-hand -2 when every suit mirrors.
@(private)
opc_per_suit_mirror_penalty :: proc(a, b: Hand_Summary) -> f32 {
	if !has_five_plus(a) && !has_five_plus(b) {
		return 0.0
	}
	penalty: f32 = 0.0
	for suit in Suit {
		la := suit_length(a, suit)
		lb := suit_length(b, suit)
		if la == lb && la <= 3 { 	// equal length, combined < 8 (non-fit)
			penalty -= 1.0
		}
	}
	return penalty
}

// Distribution-fit ("ruffing") value a hand brings as trump support once an 8+ fit exists — the
// deferred shortage the responder base held back (see opc_responder_base). With 2-4 trumps the hand is
// the SUPPORT/dummy: its single shortest side suit ruffs, worth its trump length minus that suit's
// length (a singleton opposite four trumps = 3), zero without a side shortage. With 5+ trumps it is
// itself long in trumps, so its shortages count in full as an opener's would (its whole suit
// distribution total). Fewer than two trumps is no support: nothing. (opc render_summary
// "Distribution-Fit points".) The composition applies this only for a real (8+) trump fit and only to
// the RESPONDER — the opener already carries its own shortage in its opening base.
@(private)
opc_support_ruffing :: proc(r: Responder, trump: Suit) -> f32 {
	v, _, _ := opc_support_ruffing_detail(r, trump)
	return v
}

// As opc_support_ruffing, also returning the reason and the RELEVANT suit: the shortest side suit that
// ruffs (2-4 support), or the trump suit itself (5+ long trump). `suit`/`reason` are meaningful only
// when the returned value is non-zero.
@(private)
opc_support_ruffing_detail :: proc(r: Responder, trump: Suit) -> (f32, Opc_Reason, Suit) {
	s := Hand_Summary(r)
	rt := suit_length(s, trump)
	if rt >= 5 {
		return distribution_points(s).suit, .Ruff_Long_Trump, trump // long trump: full opening-style shortage value
	}
	if rt < 2 {
		return 0.0, .None, trump // not trump support
	}
	// 2-4 card support: the single shortest side suit ruffs.
	shortest := 13
	shortest_suit := trump
	for suit in Suit {
		if suit == trump {
			continue
		}
		l := suit_length(s, suit)
		if l < shortest {
			shortest = l
			shortest_suit = suit
		}
	}
	ruff := rt - shortest
	if ruff > 0 {
		return f32(ruff), .Ruff_Support, shortest_suit
	}
	return 0.0, .None, trump
}

// The most labelled entries a breakdown can hold: per suit at most fit + two misfit + two wasted + two
// weak-fit = 7, over four suits = 28, plus ruffing and the whole-hand mirror and four per-suit mirrors.
MAX_OPC_ENTRIES :: 40

// One labelled contribution to a combined-OPC total — the granular detail the reference render_summary
// lists per suit (WHICH suit, WHY, how much), rather than only a summed family total. Whole-hand mirror
// is the one entry with `has_suit=false` (it is a shape property, not a single suit).
Opc_Entry :: struct {
	suit:     Suit,
	value:    f32,
	reason:   Opc_Reason,
	has_suit: bool,
}

// A per-adjustment breakdown of a combined-OPC evaluation. Three layers of detail, each summing to
// `total`:
//   1. the two base totals (opener/responder), each further split into its H/L/D components;
//   2. the per-family sums (fit / misfit / wasted / weak_fit / ruffing / mirror);
//   3. the individual labelled `entries` (which suit, which reason) — the full render_summary detail.
// Every value is signed; `misfit`, `wasted` and `mirror` are typically <= 0 (freed honours make
// `wasted` positive), the rest >= 0. `entries[:n_entries]` are the live ones.
Opc_Breakdown :: struct {
	total:          f32, // == opener_base + responder_base + fit + misfit + wasted + weak_fit + ruffing + mirror
	opener_base:    f32, // the stronger hand's full opening total (keeps any aceless dock)
	opener_h:       f32, // opener honour component (== opening honour, incl. aceless dock)
	opener_l:       f32, // opener length component
	opener_d:       f32, // opener distribution component (suit or nt per strain) — opener_base == h+l+d
	responder_base: f32, // the weaker hand's capped responder base
	responder_h:    f32, // responder honour component (non-opening)
	responder_l:    f32, // responder length (CAPPED at 2 for a suit; full for NT)
	responder_d:    f32, // responder distribution (suit: only the -1 4333 flat; NT: full nt) — base == h+l+d
	fit:            f32, // opc_fit_points summed over every 8+ combined suit (double fits stack)
	misfit:         f32, // shortage/working-doubleton opposite partner's 5+ suit (opc_opposite_long_suit)
	wasted:         f32, // honours opposite partner's shortage — negative wasted, positive freed
	weak_fit:       f32, // weak picture holdings firming up inside a fit (opc_weak_honour_fit_upgrade)
	ruffing:        f32, // responder distribution-fit ruffing value, only with a real (8+) trump fit
	mirror:         f32, // whole-hand + per-suit mirror penalties (<= 0)
	entries:        [MAX_OPC_ENTRIES]Opc_Entry, // labelled per-adjustment detail; only [:n_entries] valid
	n_entries:      int,
}

// Append a labelled entry, skipping the no-ops (zero value or `.None` reason) and never overflowing the
// fixed store. `has_suit` is false only for the whole-hand mirror.
@(private = "file")
opc_push :: proc(r: ^Opc_Breakdown, suit: Suit, value: f32, reason: Opc_Reason, has_suit := true) {
	if reason == .None || value == 0 {
		return
	}
	if r.n_entries >= MAX_OPC_ENTRIES {
		return
	}
	r.entries[r.n_entries] = Opc_Entry{suit, value, reason, has_suit}
	r.n_entries += 1
}

// The partnership's combined OPC for a contract of the given strain, broken into its component
// adjustments (see Opc_Breakdown). `a` and `b` are INTERCHANGEABLE — the roles are derived from the
// hands, not from argument position, so swapping them returns the same breakdown. The stronger hand
// (higher non-opening total) is treated as the
// OPENER — keeping its full opening total, including any aceless dock — while the weaker RESPONDS with
// its capped responder base (see opc_responder_base). To that base it adds, per suit: fit points for
// every 8+ combined length (so a DOUBLE fit counts twice), a misfit/semi-fit where one hand is long
// opposite the other's shortage or working doubleton, and wasted/freed honour value where one hand
// holds honours opposite the other's shortage; weak honours in a fit firm up; whole-hand and per-suit
// mirror penalties. The long-vs-short case can draw BOTH a shape misfit (on the short hand) and a
// wasted-honour penalty (on the long hand's honours) — they are different hands' contributions and
// intentionally stack.
//
// The `trump` parameter (nil = notrump) selects the strain: it picks the suit-vs-NT base totals and, for
// a suit contract with a real (8+) trump fit, adds the responder's distribution-fit ruffing value — the
// deferred shortage the responder base held back. No double count: the opener carries its own shortage
// in its opening base, the responder's returns here.
combined_opc_breakdown :: proc(a, b: Hand_Summary, trump: Maybe(Suit)) -> Opc_Breakdown {
	is_nt := trump == nil
	oa := opc_points(a)
	ob := opc_points(b)
	a_non := oa.non_opening_nt if is_nt else oa.non_opening_suit
	b_non := ob.non_opening_nt if is_nt else ob.non_opening_suit

	// Stronger hand (by non-opening total) opens; the weaker responds with its capped base. This is the
	// ONE place the roles are decided — from here they travel as `Opener`/`Responder`, so the asymmetric
	// adjustments below cannot be handed the wrong hand.
	opener: Opener
	responder: Responder
	oo, ro: Opc_Points // the opener's / responder's own single-hand valuations
	if a_non >= b_non {
		opener, responder, oo, ro = Opener(a), Responder(b), oa, ob
	} else {
		opener, responder, oo, ro = Opener(b), Responder(a), ob, oa
	}

	r: Opc_Breakdown
	// Opener base, split into its H/L/D components (opening honour keeps any aceless dock).
	r.opener_h = oo.honour.opening
	r.opener_l = oo.length
	r.opener_d = oo.distribution.nt if is_nt else oo.distribution.suit
	r.opener_base = r.opener_h + r.opener_l + r.opener_d

	// Responder base, likewise split. A SUIT responder caps length at 2 and its distribution shrinks to
	// only the -1 flat-4333 penalty (shortage waits for a fit, returning later as ruffing); NT lifts both.
	r.responder_h = ro.honour.non_opening
	if is_nt {
		r.responder_l = ro.length
		r.responder_d = ro.distribution.nt
	} else {
		rl := ro.length
		if rl > 2.0 {rl = 2.0}
		r.responder_l = rl
		r.responder_d = -1.0 if is_4333(Hand_Summary(responder)) else 0.0
	}
	r.responder_base = r.responder_h + r.responder_l + r.responder_d

	for suit in Suit {
		ma := a.suits[suit]
		mb := b.suits[suit]
		la := suit_length(a, suit)
		lb := suit_length(b, suit)
		combined := la + lb

		fp := opc_fit_points(combined)
		r.fit += fp
		opc_push(&r, suit, fp, .Fit)

		if la >= 5 {
			v, why := opc_opposite_long_suit_detail(mb, lb)
			r.misfit += v
			opc_push(&r, suit, v, why)
		}
		if lb >= 5 {
			v, why := opc_opposite_long_suit_detail(ma, la)
			r.misfit += v
			opc_push(&r, suit, v, why)
		}

		if lb <= 1 {
			v, why := opc_honour_opposite_shortage_detail(ma, lb)
			r.wasted += v
			opc_push(&r, suit, v, why)
		}
		if la <= 1 {
			v, why := opc_honour_opposite_shortage_detail(mb, la)
			r.wasted += v
			opc_push(&r, suit, v, why)
		}

		if combined >= 8 {
			wa := opc_weak_honour_fit_upgrade(ma)
			wb := opc_weak_honour_fit_upgrade(mb)
			r.weak_fit += wa + wb
			opc_push(&r, suit, wa, .Weak_Honour_Fit)
			opc_push(&r, suit, wb, .Weak_Honour_Fit)
		}
	}

	// Responder's ruffing value, once a genuine trump fit backs the strain.
	if t, is_suit := trump.?; is_suit {
		if suit_length(Hand_Summary(opener), t) + suit_length(Hand_Summary(responder), t) >= 8 {
			v, why, rsuit := opc_support_ruffing_detail(responder, t)
			r.ruffing = v
			opc_push(&r, rsuit, v, why)
		}
	}

	whole := opc_mirror_penalty(a, b)
	r.mirror = whole + opc_per_suit_mirror_penalty(a, b)
	opc_push(&r, Suit.Spades, whole, .Whole_Hand_Mirror, false) // suit is a placeholder; has_suit=false
	// Per-suit mirror entries: re-derive the same condition opc_per_suit_mirror_penalty sums (a same-suit
	// equal short length, gated on a 5+ suit) so each mirrored suit is shown individually. Keep in step
	// with that proc.
	if has_five_plus(a) || has_five_plus(b) {
		for suit in Suit {
			la := suit_length(a, suit)
			lb := suit_length(b, suit)
			if la == lb && la <= 3 {
				opc_push(&r, suit, -1.0, .Per_Suit_Mirror)
			}
		}
	}

	r.total = r.opener_base + r.responder_base + r.fit + r.misfit + r.wasted + r.weak_fit + r.ruffing + r.mirror
	return r
}

// The partnership's combined OPC total for a contract of the given strain — just the `.total` of
// combined_opc_breakdown (see there for the full composition). Call the breakdown form when the
// component adjustments are wanted too.
combined_opc :: proc(a, b: Hand_Summary, trump: Maybe(Suit)) -> f32 {
	return combined_opc_breakdown(a, b, trump).total
}
