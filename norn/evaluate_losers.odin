package norn

/*
	evaluate_losers.odin — the trickier evaluation primitives.

	`evaluate.odin` holds the obvious counts (suit lengths, hcp, controls, shape, balanced). This
	file holds the four `deal` evaluators our `deal-utils.tcl` predicates lean on that are NOT
	one-liners — the loser/offense estimators and the two notrump-shape / honour-weight helpers.
	They are generic bridge evaluation (no system policy), so they belong in `norn`:

	  - `is_nt5cM_shape`  — the `5CM_nt` shape test (deal `lib/utility.tcl`), minus the hcp range.
	  - `losers`          — refined HALF-loser count (deal builtin `losers`); see its doc comment.
	  - `offense`         — per-suit offensive-trick estimate (deal's v2/v1 `offense` hybrid).
	  - `top5q`           — weighted honours A/K/Q=2, J/T=1 (deal `defvector Top5Q 2 2 2 1 1`).

	`losers` and `offense` are reproduced to the digit against deal.exe — both were originally ported
	from a wrong reading of the Tcl and corrected after probing the real engine (see their comments).
	All are pure functions of a `Hand` (and a `Suit`, where per-suit). See `deal319-reference.md` for
	how these map back to the engine being replaced.
*/

// Does the hand have a "5CM_nt" shape: a notrump shape that may include a 5-card suit but is NOT a
// 5-4? This is deal's `5CM_nt` shape test with the hcp range stripped out (callers pair it with an
// `hcp` range themselves). The admitted shapes are exactly 4-3-3-3, 4-4-3-2 and 5-3-3-2 (the 5 may
// be a major — hence "5-card-major notrump").
//
// The rule: every suit is a 2-, 3-, 4- or 5-carder (no void, singleton, or 6+ suit), and the hand
// is not simultaneously 5-something and 4-something (which would be a 5-4-2-2). An 8+ suit can't
// occur here anyway — it forces a short suit elsewhere — so checking lengths 2..5 is sufficient.
is_nt5cM_shape :: proc(hand: Hand) -> bool {
	has_four := false
	has_five := false
	for suit in Suit {
		length := suit_length(hand, suit)
		if length < 2 || length > 5 {
			return false
		}
		if length == 4 {
			has_four = true
		}
		if length == 5 {
			has_five = true
		}
	}
	// A hand holding both a 5-card and a 4-card suit is a 5-4-2-2 — not a notrump shape here.
	return !(has_four && has_five)
}

// Losing Trick Count for the whole hand, matching deal's `losers` builtin EXACTLY — including its
// two quirks, both verified by probing deal.exe over every honour combination:
//
//   1. It returns HALF-losers (a refinement deal kept for historical reasons): every value is
//      doubled, so a normal three-loser suit is 6, an average opening hand ~14-15, not ~7. The
//      ported predicates (`is_8_plus_tricks` `losers<=5`, `is_potential_4n_opener` `losers<=3`) were
//      written against these half-loser thresholds, so this MUST stay in half-loser units.
//   2. The queen gets a refinement: a held queen only fully covers its loser slot when "backed" by
//      another honour (A, K, J or T) in the suit; an unbacked queen (e.g. Qxx) covers only half.
//
// Per suit there are min(length, 3) loser "slots", covered top-down by A, then K, then Q:
//   - missing ace            -> +2 half-losers
//   - missing king  (len>=2) -> +2
//   - queen slot    (len>=3): missing -> +2; present-but-unbacked -> +1; present-and-backed -> 0
losers :: proc(hand: Hand) -> int {
	total := 0
	for suit in Suit {
		length := suit_length(hand, suit)
		if length == 0 {
			continue
		}
		ace := holds(hand, suit, .Ace)
		king := holds(hand, suit, .King)
		if !ace {
			total += 2
		}
		if length >= 2 && !king {
			total += 2
		}
		if length >= 3 {
			if !holds(hand, suit, .Queen) {
				total += 2
			} else if !(ace || king || holds(hand, suit, .Jack) || holds(hand, suit, .Ten)) {
				// An unbacked queen (e.g. Qxx) is only half a cover.
				total += 1
			}
		}
	}
	return total
}

// `baselose` table, indexed by suit length 0..13: the crude number of losers a suit of that length
// has before honours are considered. `offense` uses it to pick how hard to look at the top cards.
// (deal: `set Losers($len)` in `lib/utility.tcl` / `lib/evaluators.tcl`.)
@(private = "file")
BASE_LOSERS := [RANK_COUNT + 1]int{0, 1, 2, 3, 4, 4, 3, 3, 2, 2, 2, 1, 1, 0}

// Sum of `weights` over the top ranks the hand holds in `suit`, applied from the ace downward:
// `weights[0]` is scored if the ace is held, `weights[1]` for the king, and so on through
// A K Q J T 9 8. This is exactly how deal's `defvector` honour vectors evaluate (e.g. `Top5Q`,
// `losers1_4`). Ranks past the end of `weights` contribute nothing.
@(private = "file")
suit_top_weighted :: proc(hand: Hand, suit: Suit, weights: []int) -> int {
	// The ranks scored, highest first; one slot per possible weight.
	ranks := [7]Rank{.Ace, .King, .Queen, .Jack, .Ten, .Nine, .Eight}
	sum := 0
	for weight, i in weights {
		if holds(hand, suit, ranks[i]) {
			sum += weight
		}
	}
	return sum
}

// Estimated offensive tricks from `suit`: roughly how many tricks the suit pulls when it is trumps.
// Matches deal's `offense` EXACTLY (verified by probing deal.exe over every honour combination).
//
// deal's `offense` is a hybrid: the `holdingProc` in `lib/evaluators.tcl` for all the longer-suit
// cases (baselose 2/3/4), but `lib/utility.tcl`'s `len-1+ace` for the lone-loser case (baselose 1).
// Start from the suit length and dock losers by which top honours are missing; a solid suit returns
// its full length, a ragged one several fewer. Used by the preempt predicates (`is_tricky_suit`,
// `any_offensive_suit`).
offense :: proc(hand: Hand, suit: Suit) -> int {
	length := suit_length(hand, suit)
	a := holds(hand, suit, .Ace)
	k := holds(hand, suit, .King)
	q := holds(hand, suit, .Queen)
	j := holds(hand, suit, .Jack)
	t := holds(hand, suit, .Ten)
	n9 := holds(hand, suit, .Nine)
	n8 := holds(hand, suit, .Eight)
	// Honour counts for the baselose-4 weighted tests.
	ai := int(a); ki := int(k); qi := int(q); ji := int(j); ti := int(t); n9i := int(n9); n8i := int(n8)

	switch BASE_LOSERS[length] {
	case 0:
		return length
	case 1:
		// One nominal loser, redeemed only by the ace (deal uses utility.tcl's form here).
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

// Weighted top-honour count for `suit`: ace, king and queen score 2 each; jack and ten score 1
// each (deal `defvector Top5Q 2 2 2 1 1`). A solid AKQ is 6; AKQJT is 8. Used to judge suit
// quality (`long_semi_solid`, `good_6_plus_suit`).
top5q :: proc(hand: Hand, suit: Suit) -> int {
	return suit_top_weighted(hand, suit, {2, 2, 2, 1, 1})
}
