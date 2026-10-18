package combo

/*
	lines.odin — Phase 2, brick 2: the candidate-line generator.

	Brick 1 (`single_dummy.odin`) SCORES one blind line. This file supplies a small set of real,
	generic blind lines — the strategic axes a declarer actually chooses among in a single suit — and
	the machinery to compare them:

	  * `line_top_down`         (in single_dummy.odin) — cash the highest card every trick; never finesse.
	                             The "play for the drop" baseline.
	  * `line_finesse`          — lead low toward the hand with the tenace; it inserts its cheapest
	                             FINESSE card above the card winning (`finesse_insert`), never overtaking a
	                             winning top card. The "take the finesse" line.
	  * `line_duck_one`         — concede the first round (both hands play low), then cash top-down. The
	                             "duck to keep control / prepare a long suit" line.
	  * `line_finesse_other`    — the finesse taken the OTHER way (lead low toward the WEAKER honour
	                             hand). On a two-way holding this is a genuinely different guess; the DP
	                             picks whichever direction scores better (on a genuine two-way it just
	                             exposes the guess, matching brick 3's finding).
	  * `line_finesse_high`     — the finesse against the highest missing honour only (the J of AQJ952
	                             opposite 8743, against the king), then cash; `line_finesse` takes every
	                             finesse card in turn, a deep one first (the 9 against the ten).
	  * `line_finesse_then_run` — one finesse round, then `line_run` (J3 opposite KT9842: low to the 8, then
	                             run the J).
	  * `line_cash_then_discover` — cash one top card; if a defender shows out, finesse through the other
	                             (A K J T 8 6 opposite 9 4 3 2: the ace, then toward the K J T).
	  * `line_duck_then_finesse` — a COMPOUND line: duck the first round (both hands low), THEN finesse on
	                             every later round. The canonical entry-preserving / rectify-the-count
	                             manoeuvre that a single-phase line cannot express.

	These are deliberately GENERIC heuristics (they apply to any holding), not the per-holding optimum —
	finding that is brick 3 (the optimal single-dummy SEARCH). Their job here is to give brick 4's DP a
	real, cheap set of alternatives to choose among. Redundant candidates are harmless: `pareto_lines`
	drops dominated lines and de-dups clones (e.g. `line_finesse_other` collapses into `line_finesse`
	when the holding is one-way).

	The comparison tools:
	  * `suit_candidate_lines` evaluates every candidate on a holding -> a `Line_Result` per line.
	  * `pareto_lines` keeps only the NON-DOMINATED ones: line A dominates B when A's P(>= k) tail is
	    at least B's for every k and strictly greater for some k. What survives is the Pareto frontier —
	    for any make-target you might pick, the best line for it is in this set (the doc's "candidate set
	    = the Pareto lines, one maximising P(>= k) per k").
	  * `best_line` picks the single line maximising P(>= target) (ties broken by mean tricks) — the
	    one-suit answer that brick 4 will generalise into a residual-target DP across all four suits.
*/

// A named line together with the trick distribution it achieves on a given holding (single-dummy,
// double-dummy defence — from brick 1's `sd_line_distribution`).
Line_Result :: struct {
	name: string,
	dist: Suit_Trick_Dist,
}

// The generic candidate lines, in a stable order. Returned by value (a small fixed array of constant
// `Sd_Line`s) so callers needn't manage storage. Adding a line here makes it flow automatically through
// the DP (brick 4), `best_line`/`best_line_by_mean`, the Pareto frontier, and the card-page emit — no
// other wiring; add a matching case in `describe_suit_line` (combo.odin) for its tooltip.
candidate_lines :: proc() -> [N_CANDIDATE_LINES]Sd_Line {
	return {
		line_top_down,
		line_finesse,
		line_duck_one,
		line_finesse_other,
		line_duck_then_finesse,
		line_toward,
		line_cash_then_finesse,
		line_run,
		line_duck_unless_covered,
		line_finesse_high,
		line_finesse_then_run,
		line_cash_then_discover,
	}
}

// --- shared line building blocks --------------------------------------------------------------

// The finesse partner play, third hand after the second hand has played:
//   - our card is already winning with a top card (nothing out above it): play LOW. Never overtake partner's
//     winner - double-dummy defence throws an honour under our ace to make exactly that happen, and it did:
//     West's queen under South's ace drew North's king, and KJ85 opposite A4 lost a trick.
//   - else the cheapest FINESSE card that beats the card winning now (`finesse_card`: the J of KJ85, the Q
//     of AQ, the T of KTx opposite AJx);
//   - else as `line_top_down` (the cheapest top card that beats it, a cover; else low).
// The cheapest card that merely beats the second hand is not a finesse: on KJ85 it put in the 5 over West's 2.
// Shared by every finesse line, including the finesse phase of `line_duck_then_finesse`.
@(private)
finesse_insert :: proc(v: Sd_View) -> int {
	out := FULL_SUIT & ~(v.north | v.south | v.played)
	ns := v.north | v.south
	if v.win_ns && top_card(v.win_rank, max(highest_rank(ns), v.win_rank), out) {
		return lowest_rank(v.own)
	}
	m := v.own
	for m != 0 {
		r := lowest_rank(m)
		m &= m - 1
		if r > v.win_rank && finesse_card(r, out) {
			return r
		}
	}
	return cash_partner(v)
}

// Whether our card `r` is a FINESSE card: the first card above it that is not ours or already played is a
// defenders' honour (Ten or higher) - the card the finesse is taken against. That includes a top honour: the
// K of K743, led toward, is a finesse against the ace.
// Our own cards in between are equals of `r` (with K T opposite A J, the ten finesses against the queen too).
// Small cards below a small missing card are not (the 5 and the 8 of KJ85: a six and a nine are out above).
@(private)
finesse_card :: proc "contextless" (r: int, out: u16) -> bool {
	for k := r + 1; k <= RANK_ACE; k += 1 {
		if out & rank_bit(k) != 0 {
			return k >= RANK_TEN
		}
	}
	return false
}

@(private)
holds_finesse_card :: proc "contextless" (hand, out: u16) -> bool {
	m := hand
	for m != 0 {
		r := lowest_rank(m)
		m &= m - 1
		if finesse_card(r, out) {
			return true
		}
	}
	return false
}

// The hand holding a finesse card: the hand to lead TOWARD. When both do (a two-way finesse) or neither, the
// hand with the highest card (`strong_honour_seat`), whose opposite `line_finesse_other` then attacks.
@(private)
finesse_seat :: proc(north, south, played: u16) -> int {
	out := FULL_SUIT & ~(north | south | played)
	n, s := holds_finesse_card(north, out), holds_finesse_card(south, out)
	if n != s {
		return SEAT_N if n else SEAT_S
	}
	return strong_honour_seat(north, south)
}

// The seat holding the single highest NS card (the "strong" honour hand line_finesse leads toward);
// its opposite is the weaker honour hand `line_finesse_other` attacks.
@(private)
strong_honour_seat :: proc(north, south: u16) -> int {
	return SEAT_N if (north != 0 && (south == 0 || highest_rank(north) >= highest_rank(south))) else SEAT_S
}

// THE FINESSE PHASE, shared by every finesse line after any opening move of its own. The TARGET hand is fixed
// from the STARTING holdings (`Sd_View.start`), so a line keeps to the finesse it set out to take: while the
// target still holds a finesse card and the other hand has a card to lead, lead low toward it and insert
// (`finesse_insert`); then cash as `line_top_down`. A target worked out from the CURRENT holdings switched
// sides once its finesse card was spent: AJ2 opposite KT3 finessed the jack, then the ten through the other
// defender, lost it to the queen and blocked the ace and king (2.0 tricks instead of 2.5).
@(private)
finesse_phase_lead :: proc(north, south, played: u16, trick_no: int, target: int) -> (seat: int, rank: int) {
	target_hold := north if target == SEAT_N else south
	other_hold := south if target == SEAT_N else north
	out := FULL_SUIT & ~(north | south | played)
	if other_hold != 0 && holds_finesse_card(target_hold, out) {
		return other_seat(target), lowest_rank(other_hold)
	}
	return cash_lead(north, south, played, trick_no)
}

// The finesse phase's second card: the target hand finesses (`finesse_insert`), the other cashes.
@(private)
finesse_phase_partner :: proc(v: Sd_View, target: int) -> int {
	return finesse_insert(v) if v.seat == target else cash_partner(v)
}

// The hand `line_finesse` finesses toward, from the starting holdings; `line_finesse_other` takes the other.
@(private)
finesse_target :: proc(start: [2]u16) -> int {
	return finesse_seat(start[0], start[1], 0)
}

@(private)
other_seat :: proc "contextless" (seat: int) -> int {
	return SEAT_S if seat == SEAT_N else SEAT_N
}

// `line_finesse` — lead low toward the hand with the tenace (the J of KJ85 opposite A4, the Q of AQ) and
// insert the finesse card unless the second hand covers; repeat while it lasts, then cash. With no tenace
// it degrades to cashing.
line_finesse :: Sd_Line {
	name = "finesse",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		return finesse_phase_lead(north, south, played, trick_no, finesse_target(start))
	},
	partner = proc(v: Sd_View) -> int {
		return finesse_phase_partner(v, finesse_target(v.start))
	},
}

// `line_finesse_other` — the finesse taken the OTHER way, toward the hand `line_finesse` does not attack. On
// a two-way holding (AJx opposite KTx) it is the other guess, so the DP picks the better one; on a one-way
// holding the other hand has no finesse card and it cashes (and the Pareto frontier drops it).
line_finesse_other :: Sd_Line {
	name = "finesse-other",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		return finesse_phase_lead(north, south, played, trick_no, other_seat(finesse_target(start)))
	},
	partner = proc(v: Sd_View) -> int {
		return finesse_phase_partner(v, other_seat(finesse_target(v.start)))
	},
}

// `line_finesse_high` — finesse ONCE PER ROUND against the highest honour missing at the start, then cash: the
// J of AQJ95 opposite 8743, against the king, repeated while the king is out - and nothing after it. The 9 is a
// finesse card too (against the ten), and `line_finesse`, which inserts the cheapest finesse card, takes that
// deep finesse first and again after the jack loses to East's king: 5.0 tricks against the book's 5.5. Neither
// rule is right everywhere - with AQT opposite 432 the deep finesse first IS the book line (two tricks 76%) - so
// both are candidates and the comparison picks.
line_finesse_high :: Sd_Line {
	name = "finesse-high",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		target := finesse_target(start)
		other_hold := south if target == SEAT_N else north
		if other_hold != 0 && top_finesse_card(north if target == SEAT_N else south, north | south | played, start, -1) >= 0 {
			return other_seat(target), lowest_rank(other_hold)
		}
		return cash_lead(north, south, played, trick_no)
	},
	partner = proc(v: Sd_View) -> int {
		if v.seat != finesse_target(v.start) {
			return cash_partner(v)
		}
		out := FULL_SUIT & ~(v.north | v.south | v.played)
		if v.win_ns && top_card(v.win_rank, max(highest_rank(v.north | v.south), v.win_rank), out) {
			return lowest_rank(v.own)
		}
		if r := top_finesse_card(v.own, v.north | v.south | v.played, v.start, v.win_rank); r >= 0 {
			return r
		}
		return cash_partner(v)
	},
}

// The cheapest card of `hand` that finesses against the highest card the defenders held at the START (`start`),
// while that card is still out (`seen`: every card not the defenders' now), and above `above` (the card winning
// the trick): the J of AQJ95 against the king. -1 when there is none - the honour has gone, or `hand` has no
// card in the run just below it. The run stops at `above`: once the defenders' ten has been played every card
// below the king is seen, and the cheapest of the run would be the 5.
@(private)
top_finesse_card :: proc "contextless" (hand, seen: u16, start: [2]u16, above: int) -> int {
	honour := highest_rank(FULL_SUIT & ~(start[0] | start[1]))
	if honour < RANK_TEN || seen & rank_bit(honour) != 0 {
		return -1
	}
	best := -1
	for r := honour - 1; r > above && seen & rank_bit(r) != 0; r -= 1 {
		if hand & rank_bit(r) != 0 {
			best = r
		}
	}
	return best
}

// `line_duck_then_finesse` — a COMPOUND (phased) line: concede the first round (lead low, partner low),
// THEN the finesse phase. Ducking once can rectify the count / keep an entry for a repeated finesse — a
// manoeuvre no single-phase line can express. Uses the threaded `trick_no` to switch phases.
line_duck_then_finesse :: Sd_Line {
	name = "duck-then-finesse",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		if trick_no == 0 {
			// First round: duck — lead low from a non-void hand.
			if south != 0 {
				return SEAT_S, lowest_rank(south)
			}
			return SEAT_N, lowest_rank(north)
		}
		return finesse_phase_lead(north, south, played, trick_no, finesse_target(start))
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return lowest_rank(v.own) // duck the first round: play low even if we could win
		}
		return finesse_phase_partner(v, finesse_target(v.start))
	},
}

// `line_duck_one` — concede the opening round (lead low, partner low), then cash top-down. Ducking
// once can strip the defenders' small cards / preserve a stopper; whether it gains is holding-specific,
// which is exactly why it is a distinct candidate for the frontier to keep or discard.
line_duck_one :: Sd_Line {
	name = "duck-one",
	lead = proc(north, south, played: u16, trick_no: int, _: [2]u16, _: u8) -> (seat: int, rank: int) {
		if played == 0 {
			// First trick of the suit: lead low (duck) from a non-void hand.
			if south != 0 {
				return SEAT_S, lowest_rank(south)
			}
			return SEAT_N, lowest_rank(north)
		}
		// Thereafter cash, as `line_top_down`.
		return cash_lead(north, south, played, trick_no)
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return lowest_rank(v.own) // the duck: low even when we could win
		}
		return cash_partner(v)
	},
}

// `line_toward` - cash as `line_top_down` does, but lead LOW from the long hand TOWARD the short hand's top
// cards instead of leading them: the short hand then plays after the second hand, and so takes its cheapest
// top card that beats it. K J 3 opposite A Q 9 8 7: lead toward the K J, not the K, and a defender with
// T 6 5 4 2 is caught.
line_toward :: Sd_Line {
	name = "toward",
	lead = proc(north, south, played: u16, trick_no: int, _: [2]u16, _: u8) -> (seat: int, rank: int) {
		seat, rank = cash_lead(north, south, played, trick_no)
		other := south if seat == SEAT_N else north
		out := FULL_SUIT & ~(north | south | played)
		if other != 0 && top_card(rank, highest_rank(north | south), out) {
			// The short hand would lead a top card: lead low from the long hand toward it instead.
			return SEAT_S if seat == SEAT_N else SEAT_N, lowest_rank(other)
		}
		return
	},
	partner = cash_partner,
}

// `line_cash_then_finesse` - cash the single highest card first (against a singleton honour), then finesse
// as the finesse phase. A K T 4 opposite J 7: the king, then low toward the J.
line_cash_then_finesse :: Sd_Line {
	name = "cash-then-finesse",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		if trick_no == 0 {
			if north != 0 && (south == 0 || highest_rank(north) > highest_rank(south)) {
				return SEAT_N, highest_rank(north)
			}
			return SEAT_S, highest_rank(south)
		}
		return finesse_phase_lead(north, south, played, trick_no, finesse_target(start))
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return lowest_rank(v.own)
		}
		return finesse_phase_partner(v, finesse_target(v.start))
	},
}

// `line_run` - RUN the weak hand's cards: lead its highest card while that is a ten or better, and let it
// ride (the other hand plays low) unless the second hand covers, then cover with the cheapest card that
// beats it. J 10 7 opposite A K 6 5 3 runs the jack and the ten through the queen; A J 9 opposite 10 runs the
// ten. Once the weak hand has no ten or better, it cashes as `line_top_down`.
line_run :: Sd_Line {
	name = "run",
	lead = proc(north, south, played: u16, trick_no: int, _: [2]u16, _: u8) -> (seat: int, rank: int) {
		weak := SEAT_S if strong_honour_seat(north, south) == SEAT_N else SEAT_N
		hold := north if weak == SEAT_N else south
		if hold != 0 && highest_rank(hold) >= 8 && north != 0 && south != 0 {
			return weak, highest_rank(hold)
		}
		return cash_lead(north, south, played, trick_no)
	},
	partner = proc(v: Sd_View) -> int {
		if v.win_ns && v.win_rank >= 8 {
			return lowest_rank(v.own) // our ten or better is winning: let it run
		}
		return cash_partner(v) // covered: cover in turn; or cashing, as `line_top_down`
	},
}

// `line_finesse_then_run` - one round of the finesse phase (low toward the tenace, the finesse card in), then
// `line_run`: lead the weak hand's honour and let it ride unless covered. J3 opposite KT9842: low to the 8,
// then run the J. `line_finesse` leads the J on the second round as well, but overtakes it with the K when
// East plays low (the J is not a top card while the Q is out), and `line_run` runs the J at once. The exact
// search takes this line on every layout of that holding (4.37 tricks against 4.16), and on a sweep of random
// holdings it moved 8 of 225, none worse.
line_finesse_then_run :: Sd_Line {
	name = "finesse-then-run",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, _: u8) -> (seat: int, rank: int) {
		if trick_no == 0 {
			return finesse_phase_lead(north, south, played, trick_no, finesse_target(start))
		}
		return line_run.lead(north, south, played, trick_no, start, 0)
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return finesse_phase_partner(v, finesse_target(v.start))
		}
		return line_run.partner(v)
	},
}

// `line_cash_then_discover` - a DISCOVERY play: cash one top card, keeping the tenace (from the hand without it
// when that hand has a top card), and if a defender shows out, finesse through the other one, who now holds
// everything that is out; if both follow, cash. A K J T 8 6 opposite 9 4 3 2 (Q 7 5 out): the ace, and when East
// shows out, low toward the K J T through West's Q 7 5 - 89% for six tricks, where cashing is 78%. It reads
// who showed out (`shown`), which a line could not see before 2026-10-18.
line_cash_then_discover :: Sd_Line {
	name = "cash-then-discover",
	lead = proc(north, south, played: u16, trick_no: int, start: [2]u16, shown: u8) -> (seat: int, rank: int) {
		if trick_no == 0 {
			return discovery_cash(start)
		}
		// With the count known and one card left out, cash: a bare queen drops under the ace.
		if target, ok := discovered_target(shown); ok && card_count(FULL_SUIT & ~(north | south | played)) > 1 {
			return finesse_phase_lead(north, south, played, trick_no, target)
		}
		return cash_lead(north, south, played, trick_no)
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no > 0 {
			if target, ok := discovered_target(v.shown); ok {
				return finesse_phase_partner(v, target)
			}
		}
		return cash_partner(v)
	},
}

// The discovery's first card: a top card from the hand that does NOT hold the card just below the top missing
// honour (the J of KJ8542 against the Q: cash South's A, keep the K J), or that hand's top card when the other
// has none. When both hands or neither have such a card, the lines' usual target is the hand kept.
@(private)
discovery_cash :: proc(start: [2]u16) -> (seat: int, rank: int) {
	keep := finesse_target(start)
	n := top_finesse_card(start[0], start[0] | start[1], start, -1) >= 0
	s := top_finesse_card(start[1], start[0] | start[1], start, -1) >= 0
	if n != s {
		keep = SEAT_N if n else SEAT_S
	}
	other := other_seat(keep)
	other_hold := start[0] if other == SEAT_N else start[1]
	out := FULL_SUIT & ~(start[0] | start[1])
	if other_hold != 0 && top_card(highest_rank(other_hold), highest_rank(start[0] | start[1]), out) {
		return other, highest_rank(other_hold)
	}
	return keep, highest_rank(start[0] if keep == SEAT_N else start[1])
}

// The hand to finesse toward once exactly one defender has shown out: the hand that plays after the other one,
// who holds every card still out (East void: West holds them, so lead from South toward North).
@(private)
discovered_target :: proc "contextless" (shown: u8) -> (target: int, ok: bool) {
	switch shown {
	case SHOWN_E:
		return SEAT_N, true
	case SHOWN_W:
		return SEAT_S, true
	}
	return SEAT_N, false
}

// `line_duck_unless_covered` - lead as `line_top_down` does, but when our card is winning the trick after
// the second hand, play LOW from the other hand and let it ride: the round is ducked unless the second hand
// plays high, when we win it as cheaply as we can. Repeated every round it gives up the tricks the defenders'
// small cards must win anyway while keeping our high cards as stoppers: K 9 6 5 2 opposite A, Q 7 6 3 2
// opposite A.
line_duck_unless_covered :: Sd_Line {
	name = "duck-unless-covered",
	lead = proc(north, south, played: u16, trick_no: int, _: [2]u16, _: u8) -> (seat: int, rank: int) {
		return cash_lead(north, south, played, trick_no)
	},
	partner = proc(v: Sd_View) -> int {
		if v.win_ns {
			return lowest_rank(v.own)
		}
		return cash_partner(v)
	},
}

// --- comparing the candidates -----------------------------------------------------------------

// Evaluate every candidate line on one holding. Caller owns the returned slice.
suit_candidate_lines :: proc(north, south: u16, allocator := context.allocator) -> []Line_Result {
	lines := candidate_lines()
	out := make([]Line_Result, len(lines), allocator)
	for line, i in lines {
		out[i] = Line_Result {
			name = line.name,
			dist = sd_line_distribution(north, south, line),
		}
	}
	return out
}

// Does `b` dominate `a`? True when b's P(>= k) tail is >= a's for every k and strictly greater for at
// least one — so b is at least as good for every make-target and better for some.
@(private)
line_dominates :: proc(a, b: Suit_Trick_Dist) -> bool {
	EPS :: 1e-9
	ge_all := true
	gt_some := false
	for k in 0 ..= RANKS {
		ta := p_at_least(a.p, k)
		tb := p_at_least(b.p, k)
		if tb < ta - EPS {
			ge_all = false
			break
		}
		if tb > ta + EPS {
			gt_some = true
		}
	}
	return ge_all && gt_some
}

@(private)
dist_near_equal :: proc(a, b: Suit_Trick_Dist) -> bool {
	EPS :: 1e-9
	for k in 0 ..= RANKS {
		if abs(p_at_least(a.p, k) - p_at_least(b.p, k)) > EPS {
			return false
		}
	}
	return true
}

// The Pareto frontier of a candidate set: drop every line another line dominates, and de-duplicate
// lines with (essentially) identical distributions — keeping the first, so a stable, minimal set of
// genuinely distinct choices remains. Caller owns the returned slice.
pareto_lines :: proc(cands: []Line_Result, allocator := context.allocator) -> []Line_Result {
	keep := make([dynamic]Line_Result, allocator)
	outer: for c, i in cands {
		for other, j in cands {
			if i == j {
				continue
			}
			if line_dominates(c.dist, other.dist) {
				continue outer // dominated -> drop
			}
			if j < i && dist_near_equal(c.dist, other.dist) {
				continue outer // an earlier clone already represents this distribution
			}
		}
		append(&keep, c)
	}
	return keep[:]
}

// The single best candidate line for a target trick count: maximise P(>= target), ties broken by the
// higher mean. This is the one-suit make-line; brick 4 turns "fixed target per suit" into a
// residual-target DP that folds the four suits together under a pluggable objective.
best_line :: proc(north, south: u16, target: int) -> Line_Result {
	lines := candidate_lines()
	best: Line_Result
	best_key := f64(-1)
	best_mean := f64(-1)
	for line in lines {
		dist := sd_line_distribution(north, south, line)
		key := p_at_least(dist.p, target)
		mean := expected_tricks(dist.p)
		if key > best_key + 1e-12 || (abs(key - best_key) <= 1e-12 && mean > best_mean) {
			best_key = key
			best_mean = mean
			best = Line_Result {
				name = line.name,
				dist = dist,
			}
		}
	}
	return best
}
