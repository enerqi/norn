package conditions

/*
	conditions — bridge bidding conditions for this system (the "Weak Strong Club" system).

	These are the predicates our deal simulations are written in terms of — the Odin port of
	`deal-simulations/deal-utils.tcl`. They are system POLICY, built on the generic evaluation
	primitives in the `norn` engine (`hcp`, `is_balanced`, suit lengths, …). Keeping them in their
	own package leaves `norn` system-agnostic: the engine never knows what "a strong 1C" is.

	Each condition takes a `norn.Hand` and returns whether it qualifies, so it composes directly into
	a `norn.Predicate` over a `Deal` (typically applied to one seat).

	This file currently holds one ported predicate as a proof of the structure; the rest of
	deal-utils.tcl ports on top of the same primitives.
*/

import "../norn"

// A "flattish" hand: balanced or semi-balanced. (deal-utils `flattish`.)
is_flattish :: proc(hand: norn.Hand) -> bool {
	return norn.is_balanced(hand) || norn.is_semibalanced(hand)
}

// Would this hand open an artificial strong 1C? (deal-utils `is_strong_1c`.)
//
// 16+ high-card points; 21+ always qualifies, while 16–20 must be unbalanced (a flat 16–20 is
// shown some other way, e.g. a strong notrump).
is_strong_1c :: proc(hand: norn.Hand) -> bool {
	points := norn.hcp(hand)
	if points < 16 {
		return false
	}
	if points >= 21 {
		return true
	}
	return !is_flattish(hand)
}
