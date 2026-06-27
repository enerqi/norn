package norn

/*
	evaluate_losers.odin — the trickier evaluation primitives.

	`evaluate.odin` holds the obvious counts (suit lengths, hcp, controls, shape, balanced). This
	file holds the four `deal` evaluators our `deal-utils.tcl` predicates lean on that are NOT
	one-liners — the loser/offense estimators and the two notrump-shape / honour-weight helpers.
	They are generic bridge evaluation (no system policy), so they belong in `norn`:

	  - `is_nt5cM_shape`  — the `5CM_nt` shape test (deal `lib/utility.tcl`), minus the hcp range.
	  - `losers`          — basic Losing Trick Count (deal builtin `losers`).
	  - `offense`         — per-suit offensive-trick estimate (deal `lib/utility.tcl` `offense`).
	  - `top5q`           — weighted honours A/K/Q=2, J/T=1 (deal `defvector Top5Q 2 2 2 1 1`).

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

// Basic Losing Trick Count for the whole hand (deal's `losers` builtin). Each suit contributes a
// loser for each of the top three cards (A, K, Q) it is MISSING, capped at the suit's length: a
// void has no losers, a singleton has at most one (the missing ace), a doubleton at most two, and
// anything longer at most three. Lower counts mean a more trick-rich hand; ~7 is an average opener.
losers :: proc(hand: Hand) -> int {
	total := 0
	for suit in Suit {
		length := suit_length(hand, suit)
		if length == 0 {
			continue
		}
		suit_losers := 0
		if !holds(hand, suit, .Ace) {
			suit_losers += 1
		}
		if length >= 2 && !holds(hand, suit, .King) {
			suit_losers += 1
		}
		if length >= 3 && !holds(hand, suit, .Queen) {
			suit_losers += 1
		}
		total += suit_losers
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
// This is deal's `lib/utility.tcl` `offense`: start from the suit length, then dock losers based on
// which top honours are missing, the cut-offs encoded as the `losersN_M` honour vectors. A solid
// suit returns its full length; a ragged one returns several fewer. Used by the preempt predicates
// (`is_tricky_suit`, `any_offensive_suit`).
offense :: proc(hand: Hand, suit: Suit) -> int {
	length := suit_length(hand, suit)
	switch BASE_LOSERS[length] {
	case 0:
		return length
	case 1:
		// One nominal loser, redeemed only by the ace.
		aces := holds(hand, suit, .Ace) ? 1 : 0
		return length - 1 + aces
	case 2:
		if suit_top_weighted(hand, suit, {50, 50}) >= 100 {return length} 	// A K
		if suit_top_weighted(hand, suit, {100, 50, 50}) >= 100 {return length - 1} 	// A, or K Q
		return length - 2
	case 3:
		if suit_top_weighted(hand, suit, {50, 25, 25}) >= 100 {return length} 	// A K Q
		if suit_top_weighted(hand, suit, {50, 50, 30, 20}) >= 100 {return length - 1}
		if suit_top_weighted(hand, suit, {100, 50, 50, 30, 20}) >= 100 {return length - 2}
		return length - 3
	case:
		// baselose == 4 (a 4- or 5-card suit).
		if suit_top_weighted(hand, suit, {40, 30, 20, 10, 10}) >= 100 {return length}
		if suit_top_weighted(hand, suit, {30, 30, 30, 30, 10, 10}) >= 100 {return length - 1}
		if suit_top_weighted(hand, suit, {40, 40, 40, 40, 10, 10, 10}) >= 100 {return length - 2}
		if suit_top_weighted(hand, suit, {100, 60, 60, 30, 10, 5, 5}) >= 100 {return length - 3}
		return length - 4
	}
}

// Weighted top-honour count for `suit`: ace, king and queen score 2 each; jack and ten score 1
// each (deal `defvector Top5Q 2 2 2 1 1`). A solid AKQ is 6; AKQJT is 8. Used to judge suit
// quality (`long_semi_solid`, `good_6_plus_suit`).
top5q :: proc(hand: Hand, suit: Suit) -> int {
	return suit_top_weighted(hand, suit, {2, 2, 2, 1, 1})
}
