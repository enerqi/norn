package norn

/*
	summary.odin — the hand representation evaluation runs on, and the evaluators over it.

	A `Hand` is 13 unordered cards; answering "how long is this suit / does it hold the king /
	what's its shape" by rescanning all 13 on every query is wasteful when a predicate fires dozens
	of such queries and reject sampling runs that predicate over millions of deals.

	A `Hand_Summary` is the per-suit index almost every query actually wants: four 16-bit masks, one
	per suit, with bit `r` set when the hand holds rank `r` (rank backing value 0..12). Built once
	from a hand in 13 ops (`summarize`), it turns the hot queries into popcount / AND / bit-test:

	  suit length   -> popcount(mask)
	  holds(r)      -> mask & (1<<r)
	  top_count(n)  -> popcount(mask & TOP_N)
	  hcp/controls  -> a few bit tests
	  pattern       -> 4 popcounts (+ sort of 4)

	The summary is a LOSSLESS re-encoding of a hand for evaluation — it drops only card ordering
	(irrelevant) and can't represent duplicates (impossible in bridge) — so every evaluator a
	predicate needs lives here, over `Hand_Summary`. `Hand` survives only where the actual cards
	matter: predeal/SmartStack construction and rendering. The generation core builds one
	`Deal_Summary` per board and hands it to the `Predicate` (see generate.odin), so a condition
	pays the 13-op build once per deal, not once per query.

	These evaluators mirror the vocabulary of the `deal` engine's Tcl library (`hcp`, `controls`,
	suit lengths, `pattern`/`shape`, `balanced`, the `TopN`/`Top5Q` honour vectors, `losers`,
	`offense`, `defense`, `OP`, `dhcp`, `newLTC`) so the ported predicates read almost line-for-line.
	`losers` and `offense` reproduce deal.exe to the digit (verified by probing it over every honour
	combination); the rest are ported straight from deal's evaluators/utility/features libraries.
*/

import "base:intrinsics"

// Per-suit rank bitmasks. `suits[suit]` has bit `int(rank)` set iff the hand holds that card.
Hand_Summary :: struct {
	suits: [Suit]u16,
}

// A whole deal's worth of summaries, indexed by seat (parallel to `Deal`).
Deal_Summary :: [Seat]Hand_Summary

// Honour bits, by rank backing value (Ace=12 … Ten=8).
@(private = "file")
ACE_BIT :: u16(1) << u16(Rank.Ace)
@(private = "file")
KING_BIT :: u16(1) << u16(Rank.King)
@(private = "file")
QUEEN_BIT :: u16(1) << u16(Rank.Queen)
@(private = "file")
JACK_BIT :: u16(1) << u16(Rank.Jack)
@(private = "file")
TEN_BIT :: u16(1) << u16(Rank.Ten)
@(private = "file")
NINE_BIT :: u16(1) << u16(Rank.Nine)
@(private = "file")
EIGHT_BIT :: u16(1) << u16(Rank.Eight)

// Masks of the top n ranks (ace downward), indexed by n (0..7, i.e. through A K Q J T 9 8).
// `TOP_MASKS[2]` is A|K. Matches the `deal` `TopN` honour vectors up to Top7.
@(private = "file")
TOP_MASKS := [8]u16 {
	0,
	ACE_BIT,
	ACE_BIT | KING_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT | TEN_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT | TEN_BIT | NINE_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT | TEN_BIT | NINE_BIT | EIGHT_BIT,
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
		s.suits[card_suit(card)] |= u16(1) << u16(card_rank(card))
	}
	return s
}

// Build summaries for all four seats of a deal.
summarize_deal :: proc(board: Deal) -> Deal_Summary {
	ds: Deal_Summary
	for seat in Seat {
		ds[seat] = summarize(board[seat])
	}
	return ds
}

// --- Counts and lookups. ---

// Number of cards held in `suit` (0..13).
suit_length :: proc(s: Hand_Summary, suit: Suit) -> int {
	return int(intrinsics.count_ones(s.suits[suit]))
}

// Named per-suit length shortcuts, mirroring deal's `spades $hand` / `hearts $hand` vocabulary.
spade_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Spades)}
heart_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Hearts)}
diamond_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Diamonds)}
club_length :: proc(s: Hand_Summary) -> int {return suit_length(s, .Clubs)}

// Does the hand hold this exact card?
holds :: proc(s: Hand_Summary, suit: Suit, rank: Rank) -> bool {
	return s.suits[suit] & (u16(1) << u16(rank)) != 0
}

// High-card points for the whole hand: Ace=4, King=3, Queen=2, Jack=1.
hcp :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if m & ACE_BIT != 0 {total += 4}
		if m & KING_BIT != 0 {total += 3}
		if m & QUEEN_BIT != 0 {total += 2}
		if m & JACK_BIT != 0 {total += 1}
	}
	return total
}

// Control count for the whole hand: Ace=2, King=1.
controls :: proc(s: Hand_Summary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if m & ACE_BIT != 0 {total += 2}
		if m & KING_BIT != 0 {total += 1}
	}
	return total
}

// How many of the top `n` ranks the hand holds in `suit` (deal's `TopN` honour vectors). `n` is
// 0..7 (A K Q J T 9 8).
top_count :: proc(s: Hand_Summary, suit: Suit, n: int) -> int {
	return int(intrinsics.count_ones(s.suits[suit] & TOP_MASKS[n]))
}

// Weighted top-honour count for `suit`: ace, king and queen score 2 each; jack and ten score 1
// each (deal `defvector Top5Q 2 2 2 1 1`). A solid AKQ is 6; AKQJT is 8.
top5q :: proc(s: Hand_Summary, suit: Suit) -> int {
	m := s.suits[suit]
	high := ACE_BIT | KING_BIT | QUEEN_BIT
	low := JACK_BIT | TEN_BIT
	return 2 * int(intrinsics.count_ones(m & high)) + int(intrinsics.count_ones(m & low))
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

@(private = "file")
PICTURE_BITS :: ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT

// Milton hcp of a single suit mask (Ace 4, King 3, Queen 2, Jack 1; Ten 0). Used by the OPC length
// component to tell a "good" (K+ / QJ) long suit from a ragged one.
@(private = "file")
milton_hcp :: proc(m: u16) -> int {
	total := 0
	if m & ACE_BIT != 0 {total += 4}
	if m & KING_BIT != 0 {total += 3}
	if m & QUEEN_BIT != 0 {total += 2}
	if m & JACK_BIT != 0 {total += 1}
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
		length := int(intrinsics.count_ones(m))
		if length == 0 {
			continue
		}

		a := m & ACE_BIT != 0
		k := m & KING_BIT != 0
		q := m & QUEEN_BIT != 0
		j := m & JACK_BIT != 0
		ten := m & TEN_BIT != 0
		// Picture honours (A/K/Q/J — the Ten is not a picture) and "small" cards (Nine down to Two).
		pics := int(intrinsics.count_ones(m & PICTURE_BITS))
		xs := length - int(intrinsics.count_ones(m & (PICTURE_BITS | TEN_BIT)))

		if a {total += 4.5}
		if k {total += 3.0}
		if q {
			// A queen "accompanied" by another picture (A/K/J) pulls its full weight; isolated it is
			// downvalued.
			if m & (ACE_BIT | KING_BIT | JACK_BIT) != 0 {
				total += 2.0
			} else {
				total += 1.5
			}
		}
		if j {
			if m & (ACE_BIT | KING_BIT | QUEEN_BIT) != 0 {
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
		if m & KING_BIT != 0 {kings += 1}
		if m & QUEEN_BIT != 0 {queens += 1}
		if m & ACE_BIT != 0 {has_ace = true}
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
		length := int(intrinsics.count_ones(m))
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

	if tripletons == 3 {total -= 1.0} // 4-3-3-3 flat
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
