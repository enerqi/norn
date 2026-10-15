package combo

/*
	lines.odin — Phase 2, brick 2: the candidate-line generator.

	Brick 1 (`single_dummy.odin`) SCORES one blind line. This file supplies a small set of real,
	generic blind lines — the strategic axes a declarer actually chooses among in a single suit — and
	the machinery to compare them:

	  * `line_top_down`         (in single_dummy.odin) — cash the highest card every trick; never finesse.
	                             The "play for the drop" baseline.
	  * `line_finesse`          — lead low toward the honour hand; the partner inserts the CHEAPEST card
	                             that beats the right-hand defender (a finesse when they play low, a cover
	                             when they play an honour). The "take the finesse" line.
	  * `line_duck_one`         — concede the first round (both hands play low), then cash top-down. The
	                             "duck to keep control / prepare a long suit" line.
	  * `line_finesse_other`    — the finesse taken the OTHER way (lead low toward the WEAKER honour
	                             hand). On a two-way holding this is a genuinely different guess; the DP
	                             picks whichever direction scores better (on a genuine two-way it just
	                             exposes the guess, matching brick 3's finding).
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
	}
}

// --- shared line building blocks --------------------------------------------------------------

// Lead low from the hand OPPOSITE `hon`, toward the honour hand (or from `hon` itself if its partner is
// void). The core "run a finesse into the tenace" lead, shared by the finesse lines.
@(private)
finesse_lead_toward :: proc(north, south: u16, hon: int) -> (seat: int, rank: int) {
	lead_seat := SEAT_S if hon == SEAT_N else SEAT_N
	lead_hold := south if lead_seat == SEAT_S else north
	if lead_hold == 0 {
		lead_seat = hon
		lead_hold = north if hon == SEAT_N else south
	}
	return lead_seat, lowest_rank(lead_hold)
}

// The finesse partner play: insert the CHEAPEST card that beats the right-hand defender (the finesse
// when they played low, a cover when they played an honour); else play low. Shared by every finesse
// line, including the finesse phase of `line_duck_then_finesse`.
@(private)
finesse_insert :: proc(v: Sd_View) -> int {
	if v.rho_rank >= 0 {
		m := v.own
		for m != 0 {
			r := lowest_rank(m)
			m &= m - 1
			if r > v.rho_rank {
				return r // lowest card strictly above RHO — iterating low->high, first hit is cheapest
			}
		}
	}
	return lowest_rank(v.own)
}

// The seat holding the single highest NS card (the "strong" honour hand line_finesse leads toward);
// its opposite is the weaker honour hand `line_finesse_other` attacks.
@(private)
strong_honour_seat :: proc(north, south: u16) -> int {
	return SEAT_N if (north != 0 && (south == 0 || highest_rank(north) >= highest_rank(south))) else SEAT_S
}

// `line_finesse` — lead low toward the honour hand and insert the cheapest card that beats the
// right-hand defender. On a tenace (AQ, KJ, ...) this is the finesse; with solid tops it degrades to
// cashing them; with nothing it just loses low. A well-defined blind line, the natural complement to
// `line_top_down`.
line_finesse :: Sd_Line {
	name = "finesse",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
		// Honour hand = the seat holding the single highest NS card; lead low toward it.
		return finesse_lead_toward(north, south, strong_honour_seat(north, south))
	},
	partner = finesse_insert,
}

// `line_finesse_other` — the same finesse taken the OTHER way: lead low toward the WEAKER honour hand
// (the seat NOT holding the single highest card). On a one-way holding this collapses to `line_finesse`
// (and the Pareto frontier dedups it); on a two-way it is a genuinely different guess, so exposing both
// directions lets the DP pick the better one — and on a true two-way it honestly surfaces the guess.
line_finesse_other :: Sd_Line {
	name = "finesse-other",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
		hon := strong_honour_seat(north, south)
		other := SEAT_S if hon == SEAT_N else SEAT_N
		return finesse_lead_toward(north, south, other)
	},
	partner = finesse_insert,
}

// `line_duck_then_finesse` — a COMPOUND (phased) line: concede the first round (lead low, partner low),
// THEN finesse toward the honour hand on every later round. Ducking once can rectify the count / keep an
// entry for a repeated finesse — a manoeuvre no single-phase line can express. Uses the threaded
// `trick_no` to switch phases (round 0 = duck, rounds >= 1 = finesse).
line_duck_then_finesse :: Sd_Line {
	name = "duck-then-finesse",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
		if trick_no == 0 {
			// First round: duck — lead low from a non-void hand.
			if south != 0 {
				return SEAT_S, lowest_rank(south)
			}
			return SEAT_N, lowest_rank(north)
		}
		return finesse_lead_toward(north, south, strong_honour_seat(north, south))
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return lowest_rank(v.own) // duck the first round: play low even if we could win
		}
		return finesse_insert(v)
	},
}

// `line_duck_one` — concede the opening round (lead low, partner low), then cash top-down. Ducking
// once can strip the defenders' small cards / preserve a stopper; whether it gains is holding-specific,
// which is exactly why it is a distinct candidate for the frontier to keep or discard.
line_duck_one :: Sd_Line {
	name = "duck-one",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
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
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
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
// toward the honour hand on every later round. A K T 4 opposite J 7: the king, then low toward the J.
line_cash_then_finesse :: Sd_Line {
	name = "cash-then-finesse",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
		if trick_no == 0 {
			if north != 0 && (south == 0 || highest_rank(north) > highest_rank(south)) {
				return SEAT_N, highest_rank(north)
			}
			return SEAT_S, highest_rank(south)
		}
		return finesse_lead_toward(north, south, strong_honour_seat(north, south))
	},
	partner = proc(v: Sd_View) -> int {
		if v.trick_no == 0 {
			return lowest_rank(v.own)
		}
		return finesse_insert(v)
	},
}

// `line_run` - RUN the weak hand's cards: lead its highest card while that is a ten or better, and let it
// ride (the other hand plays low) unless the second hand covers, then cover with the cheapest card that
// beats it. J 10 7 opposite A K 6 5 3 runs the jack and the ten through the queen; A J 9 opposite 10 runs the
// ten. Once the weak hand has no ten or better, it cashes as `line_top_down`.
line_run :: Sd_Line {
	name = "run",
	lead = proc(north, south, played: u16, trick_no: int) -> (seat: int, rank: int) {
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

// `line_duck_unless_covered` - lead as `line_top_down` does, but when our card is winning the trick after
// the second hand, play LOW from the other hand and let it ride: the round is ducked unless the second hand
// plays high, when we win it as cheaply as we can. Repeated every round it gives up the tricks the defenders'
// small cards must win anyway while keeping our high cards as stoppers: K 9 6 5 2 opposite A, Q 7 6 3 2
// opposite A.
line_duck_unless_covered :: Sd_Line {
	name = "duck-unless-covered",
	lead = cash_lead,
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
