package combo

/*
	single_dummy_opt.odin — Phase 2, brick 3: the OPTIMAL single-dummy search.

	Bricks 1–2 score/compare FIXED lines. This finds the game-optimal blind line for a suit: the most
	tricks a declarer who cannot see the E/W split can guarantee on average against perfect (double-
	dummy) defence. It is a partial-observability minimax over declarer's information sets.

	================================================================================================
	THE TWO THINGS THAT MAKE THIS HARD (and how each is handled)
	================================================================================================

	(1) DECLARER IS BLIND, so at every declarer decision the SAME card must be chosen across all the
	    layouts still consistent with what has been seen ("the belief"). We enforce this by carrying the
	    belief as an explicit weighted world-set and letting declarer nodes pick ONE action for the
	    whole set (never a per-world action — that would be "strategy fusion", cheating by seeing the
	    split).

	(2) THE DEFENCE CAN FALSE-CARD. A double-dummy defender, seeing everything, can choose WHICH of its
	    cards to play so as to pool otherwise-distinguishable layouts and hand declarer a guess. So a
	    defender node is not a per-world min — it is a min over the whole ASSIGNMENT of cards to worlds,
	    where worlds that play from the same interval become one (indistinguishable) belief for declarer's
	    future. We search that assignment exactly (`opt_defender`), one choice per interval a world holds
	    a card in - its cards there are equals (`opt_canonical`).

	Because the exact search is exponential in the number of MISSING cards, it is only tractable when NS
	holds most of the suit (few opponents' cards). Four things widen that (2026-10-14):
	  - the belief is kept in CANONICAL form (`opt_canonical`: missing cards between the same two declarer
	    cards are equals, so the layouts that differ only in them are one world);
	  - a defender's turn is a BRANCH AND BOUND over the worlds (`opt_place`), not an enumeration of the
	    product of their choices, and is memoised like a whole trick;
	  - the whole search is ALPHA-BETA over the means (see `Bound`), with each declarer position's
	    double-dummy ceiling as a free cut;
	  - a holding whose best fixed line already reaches the double-dummy census is answered at once.
	Over 400 sampled holdings with 3-8 cards missing, 200 now finish exactly within a budget of 10^7 (about
	0.4s each on average, 8.5s at most); 48 did before. 75 of the 200 beat the best fixed line, by 0.16 trick
	on average. A budget bounds the work; past it the result falls back to brick 2's best fixed line and is
	flagged `exact = false`. What still fails is mostly 5-7 missing cards with several intervals each side
	(AQ86 opposite 753 does not finish at 10^8): the fourth-hand defender searches are many and distinct.

	The recursion returns a DISTRIBUTION over tricks (not just a mean): declarer maximises / the defence
	minimises the distribution's mean, but the full vector is carried so brick 4 can later re-score it
	under a different objective (IMPs, matchpoints) by swapping the comparison key.

	Inherited from Phase 1 unchanged: free entries (declarer leads every trick) and suit isolation.

	THIS VALUE IS AN UPPER BOUND for a line played at the table: declarer answers each group knowing the
	defence's false-carding scheme. `single_dummy_policy.odin` extracts the line and values it against the
	defence that answers it, which is what a table may print (`sd_certified_line`).
*/

import "base:intrinsics"
import "core:hash/xxhash"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// Work before we give up and fall back: declarer positions plus the defence's placings, about a
// microsecond each - so the default is ~0.3s at worst, for a caller that is waiting (the advisor's
// safety-play text). An offline bake passes far more: 10^7 finishes half of all holdings.
DEFAULT_OPT_BUDGET :: 300_000

Vec :: [RANKS + 1]f64

// One layout in the belief: the opponents' current holdings in the suit plus its a-priori weight.
Opt_World :: struct {
	e, w: u16,
	wt:   f64,
}

Opt_Solver :: struct {
	budget:   int,
	overflow: bool,
	// Transposition table, keyed on a 128-bit hash of the canonical belief (`opt_canonical`): the keys
	// themselves run to a kilobyte, and a solve can store a million of them.
	memo:     map[u128]Opt_Memo,
	// Every node's scratch, given back when the node returns (`opt_solve`): only the memo outlives one.
	scratch:  ^virtual.Arena,
	dd:       map[Suit_Layout]int, // `suit_dd_tricks`' memo, for the ceiling at each declarer node
}

/*
THE BELIEF IN CANONICAL FORM, and its memo key.

Only two things about a missing card matter: which defender holds it, and which INTERVAL between
declarer's live cards it lies in. Two missing cards with no declarer card between them win and lose
exactly the same tricks, whichever defender holds which. So each world is rewritten with its cards packed
into the top of their intervals (East's first, then West's), worlds that become identical are merged with
their weights summed, and the key describes the position by those counts alone, without absolute ranks -
positions reached by different plays, or with different spot cards already gone, share it.

The merge is exact only together with how a defender's play is observed (`opt_defender`): declarer sees
which interval the card came from, not its rank. That is the restricted-choice reading of equal cards - a
defender holding several cards of one interval plays them at random, which leaves declarer exactly the
pooled belief this builds - while the CHOICE of interval stays the defence's, made double dummy.
*/
@(private)
opt_canonical :: proc(n, s: u16, worlds: []Opt_World) -> (canon: []Opt_World, key: u128) {
	sep := n | s
	live: u16
	for w in worlds {
		live |= w.e | w.w
	}
	// Each missing rank's interval: the number of declarer's cards above it.
	interval: [RANKS]int
	nonempty: [RANKS + 1]bool
	above := 0
	for r := RANKS - 1; r >= 0; r -= 1 {
		if sep & rank_bit(r) != 0 {
			above += 1
			continue
		}
		interval[r] = above
		if live & rank_bit(r) != 0 {
			nonempty[above] = true
		}
	}

	packed := make([]Opt_World, len(worlds), context.temp_allocator)
	for w, i in worlds {
		ce, cw: [RANKS + 1]int
		for r in 0 ..< RANKS {
			if w.e & rank_bit(r) != 0 {
				ce[interval[r]] += 1
			}
			if w.w & rank_bit(r) != 0 {
				cw[interval[r]] += 1
			}
		}
		e, west: u16
		for r := RANKS - 1; r >= 0; r -= 1 {
			if sep & rank_bit(r) != 0 {
				continue
			}
			j := interval[r]
			if ce[j] > 0 {
				e |= rank_bit(r)
				ce[j] -= 1
			} else if cw[j] > 0 {
				west |= rank_bit(r)
				cw[j] -= 1
			}
		}
		packed[i] = Opt_World{e, west, w.wt}
	}
	// Packing preserves the order of the counts (a higher interval is higher bits, more cards in it a
	// bigger number), so two positions with the same structure sort their worlds the same way.
	slice.sort_by(packed, proc(a, b: Opt_World) -> bool {
		if a.e != b.e {return a.e < b.e}
		return a.w < b.w
	})
	merged := make([dynamic]Opt_World, 0, len(packed), context.temp_allocator)
	for w in packed {
		if l := len(merged); l > 0 && merged[l - 1].e == w.e && merged[l - 1].w == w.w {
			merged[l - 1].wt += w.wt
		} else {
			append(&merged, w)
		}
	}

	b := strings.builder_make(context.temp_allocator)
	// The shape: declarer's cards high to low, with a mark for each interval some defender still has a
	// card in. Empty intervals vanish - the declarer cards either side of one are then equals.
	last := -1
	for r := RANKS - 1; r >= 0; r -= 1 {
		switch {
		case n & rank_bit(r) != 0:
			strings.write_byte(&b, 'N')
		case s & rank_bit(r) != 0:
			strings.write_byte(&b, 'S')
		case nonempty[interval[r]] && interval[r] != last:
			strings.write_byte(&b, 'g')
			last = interval[r]
		}
	}
	strings.write_byte(&b, '#')
	for w in merged {
		ce, cw: [RANKS + 1]u8
		for r in 0 ..< RANKS {
			if w.e & rank_bit(r) != 0 {
				ce[interval[r]] += 1
			}
			if w.w & rank_bit(r) != 0 {
				cw[interval[r]] += 1
			}
		}
		for j in 0 ..= RANKS {
			if nonempty[j] {
				strings.write_byte(&b, ce[j])
				strings.write_byte(&b, cw[j])
			}
		}
		bits := transmute(u64)w.wt
		for i in 0 ..< 8 {
			strings.write_byte(&b, u8(bits >> uint(8 * i)))
		}
	}
	return merged[:], u128(xxhash.XXH3_128(b.buf[:]))
}

// --- vector helpers ---------------------------------------------------------------------------

@(private)
vec_add :: proc(a, b: Vec) -> Vec {
	r := a
	for k in 0 ..= RANKS {
		r[k] += b[k]
	}
	return r
}

// Shift a trick distribution up by `pt` (0 or 1) tricks — used when a completed trick is won by NS.
@(private)
vec_shift :: proc(v: Vec, pt: int) -> Vec {
	if pt == 0 {
		return v
	}
	r: Vec
	for k in 0 ..< RANKS {
		r[k + 1] = v[k]
	}
	return r
}

@(private)
vec_mean :: proc(v: Vec) -> f64 {
	s := f64(0)
	for k in 0 ..= RANKS {
		s += f64(k) * v[k]
	}
	return s
}

// --- card-equivalence -------------------------------------------------------------------------

// The distinct cards `hold` can play, given the other live cards `others` (all cards still in any hand
// except this seat's). Cards of `hold` in a run uninterrupted by a live outside card are equivalent —
// we keep the lowest of each such run. (Played cards do not separate a run; they are gone.)
@(private)
canonical_plays :: proc "contextless" (hold, others: u16) -> u16 {
	res: u16
	sep := true // before the lowest card, treat as separated so the first card is always kept
	for r in 0 ..= 12 {
		bit := u16(1) << uint(r)
		if others & bit != 0 {
			sep = true
			continue
		}
		if hold & bit != 0 {
			if sep {
				res |= bit
			}
			sep = false
		}
	}
	return res
}

// --- public entry points ----------------------------------------------------------------------

// The optimal single-dummy trick distribution for a suit, and whether it is exact. When the exact
// search exceeds its budget (typically short NS holdings with many missing cards), this falls back to
// the best fixed candidate line (by mean) from brick 2 and returns `exact = false`.
sd_optimal_distribution :: proc(
	north, south: u16,
	budget := DEFAULT_OPT_BUDGET,
) -> (
	dist: Suit_Trick_Dist,
	exact: bool,
) {
	ns := north | south
	ns_len := card_count(ns)

	dist.max_tricks = ns_len
	if ns_len == 0 {
		dist.p[0] = 1
		return dist, true
	}
	if ns_len == RANKS {
		dist.p[RANKS] = 1
		return dist, true
	}

	// THE BOUNDS MEET: the best fixed line already takes the double-dummy maximum in every layout, so no
	// blind play can beat it and there is nothing to search. Most cash-outs are this, and they were some of
	// the slowest solves (A52 opposite KQ: two minutes to prove three tricks).
	best := best_line_by_mean(north, south)
	if abs(expected_tricks(best.dist.p) - expected_tricks(suit_trick_distribution(north, south).p)) < 1e-9 {
		return best.dist, true
	}

	missing := FULL_SUIT & ~ns
	m := card_count(missing)
	denom := g_binom[26][13]

	// Build the initial belief: every E/W split with its vacant-space weight.
	worlds := make([dynamic]Opt_World, 0, 1 << uint(m), context.temp_allocator)
	east := missing
	for {
		west := missing & ~east
		a := card_count(east)
		append(&worlds, Opt_World{e = east, w = west, wt = g_binom[26 - m][13 - a]})
		if east == 0 {
			break
		}
		east = (east - 1) & missing
	}

	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	sv := Opt_Solver {
		budget  = budget,
		memo    = make(map[u128]Opt_Memo),
		scratch = &scratch,
	}
	defer delete(sv.memo)
	defer delete(sv.dd)
	v: Vec
	{
		context.temp_allocator = virtual.arena_allocator(&scratch)
		v, _ = opt_solve(&sv, north, south, worlds[:], -INF, INF)
	}
	if sv.overflow {
		// Fall back to the best fixed line by mean.
		return best.dist, false
	}

	for k in 0 ..= RANKS {
		dist.p[k] = v[k] / denom
	}
	return dist, true
}

// The optimal single-dummy mean tricks for a suit (and whether exact). Convenience over the full
// distribution.
sd_optimal_expected_tricks :: proc(north, south: u16) -> (mean: f64, exact: bool) {
	dist, ok := sd_optimal_distribution(north, south)
	return expected_tricks(dist.p), ok
}

// The best fixed candidate line by mean tricks (used as the fallback when the exact search overflows).
// Public: this IS combo's blind recommendation for a holding, so callers comparing it against an external
// source — e.g. a `Suit_Book` provider diffing published percentages against ours — can ask for it directly.
best_line_by_mean :: proc(north, south: u16) -> Line_Result {
	lines := candidate_lines()
	best: Line_Result
	best_mean := f64(-1)
	for line in lines {
		d := sd_line_distribution(north, south, line)
		mn := expected_tricks(d.p)
		if mn > best_mean {
			best_mean = mn
			best = Line_Result {
				name = line.name,
				dist = d,
			}
		}
	}
	return best
}

// --- the minimax ------------------------------------------------------------------------------

/*
ALPHA-BETA over the means. Every search procedure takes `alpha` and `beta`: its caller needs the answer
exactly only when it lies strictly between them. At or below `alpha` a declarer's node is no better than
what the caller already has; at or above `beta` a defender's node is no better for the defence. So a
search stops as soon as it knows which side it is on, and says so: `.Upper` - the true value is at most
this mean - or `.Lower` - at least this. The root asks with the whole line and always gets `.Exact`.
Means are weighted trick totals (`vec_mean`), so a trick won moves the window by the worlds' weight
(`opt_trick`, at the trick's end). A bound carries no distribution; only an `.Exact` answer's vector is ever
used as one.
*/
Bound :: enum u8 {
	Exact,
	Lower,
	Upper,
}

Opt_Memo :: struct {
	v:     Vec,
	bound: Bound,
}

@(private)
INF :: 1e300

// Does a remembered answer settle a search over this window?
@(private)
memo_answers :: proc(e: Opt_Memo, alpha, beta: f64) -> bool {
	switch e.bound {
	case .Exact:
		return true
	case .Lower:
		return vec_mean(e.v) >= beta
	case .Upper:
		return vec_mean(e.v) <= alpha
	}
	return false
}

// Remember an answer; an exact one is never replaced by a bound.
@(private)
memo_store :: proc(sv: ^Opt_Solver, key: u128, v: Vec, bound: Bound) {
	if old, ok := sv.memo[key]; ok && old.bound == .Exact {
		return
	}
	sv.memo[key] = Opt_Memo{v, bound}
}

// A vector standing for a bound: its mean is `mean`, and nothing else about it means anything.
@(private)
bound_vec :: proc(mean: f64) -> Vec {
	v: Vec
	v[1] = mean
	return v
}

// Declarer on lead over `belief` (shared holdings `n`,`s`). Returns the optimal weighted trick
// distribution for the rest of the deal. Declarer maximises the distribution's mean over the lead
// choice (which hand, which card) — one choice for the whole belief.
@(private)
opt_solve :: proc(sv: ^Opt_Solver, n, s: u16, belief: []Opt_World, alpha, beta: f64) -> (Vec, Bound) {
	if sv.overflow {
		return Vec{}, .Exact
	}

	if n == 0 && s == 0 {
		total := f64(0)
		for w in belief {
			total += w.wt
		}
		r: Vec
		r[0] = total
		return r, .Exact
	}

	mark := virtual.arena_temp_begin(sv.scratch)
	defer virtual.arena_temp_end(mark)

	// Transposition memo: a hit is free (no budget spent).
	worlds, key := opt_canonical(n, s, belief)
	if e, ok := sv.memo[key]; ok && memo_answers(e, alpha, beta) {
		return e.v, e.bound
	}
	sv.budget -= 1
	if sv.budget < 0 {
		sv.overflow = true
		return Vec{}, .Exact
	}

	// THE CEILING: each world's double-dummy tricks. No blind play takes more in any world, so a lead that
	// reaches it takes exactly that in every one - its distribution is the ceiling's - and the other leads
	// need not be tried. Deep in a solve most positions are cash-outs, and this is where they end. And a
	// ceiling at or under `alpha` answers the caller without a search at all.
	ceiling := f64(0)
	for w in worlds {
		ceiling += w.wt * f64(suit_dd_tricks(Suit_Layout{n, w.e, s, w.w}, &sv.dd))
	}
	if ceiling <= alpha {
		memo_store(sv, key, bound_vec(ceiling), .Upper)
		return bound_vec(ceiling), .Upper
	}

	best: Vec
	have := false
	best_mean := f64(0)
	high := false
	a := alpha
	leads: for hand in ([2]int{SEAT_N, SEAT_S}) {
		hold := n if hand == SEAT_N else s
		if hold == 0 {
			continue
		}
		// Only distinct leads: cards in a run with no other live card between them are equivalent.
		live := n | s
		for w in worlds {
			live |= w.e | w.w
		}
		m := canonical_plays(hold, live & ~hold)
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1

			nn, ss := n, s
			if hand == SEAT_N {
				nn &= ~rank_bit(r)
			} else {
				ss &= ~rank_bit(r)
			}
			order := [4]int{hand, (hand + 1) % 4, (hand + 2) % 4, (hand + 3) % 4}
			v, _ := opt_trick(sv, nn, ss, worlds, order, 1, hand, r, rank_bit(r), a, beta)
			if sv.overflow {
				return Vec{}, .Exact
			}
			mn := vec_mean(v)
			if !have || mn > best_mean {
				best, best_mean, have = v, mn, true
			}
			if best_mean >= beta {
				high = true
				break leads
			}
			a = max(a, best_mean)
			if best_mean >= ceiling - 1e-9 {
				break leads
			}
		}
	}
	bound := Bound.Exact
	if high {
		bound = .Lower
	} else if best_mean <= alpha {
		bound = .Upper
	}
	memo_store(sv, key, best, bound)
	return best, bound
}

// One ply within a trick. `idx` counts seats already played (leader = idx 1). Declarer seats maximise
// (one card for the whole belief); defender seats minimise over the card-to-world assignment. `played` is
// declarer's cards already on this trick: gone from `n`/`s`, they still separate the defenders' cards
// (a defender may cover the ten with the jack, not with the nine).
@(private)
opt_trick :: proc(
	sv: ^Opt_Solver,
	n, s: u16,
	worlds: []Opt_World,
	order: [4]int,
	idx, win_seat, win_rank: int,
	played: u16,
	alpha, beta: f64,
) -> (
	Vec,
	Bound,
) {
	if sv.overflow {
		return Vec{}, .Exact
	}

	if idx == 4 {
		if !is_ns(win_seat) {
			return opt_solve(sv, n, s, worlds, alpha, beta)
		}
		// Declarer won the trick: one more for every world, so the window moves down by their weight.
		weight := f64(0)
		for w in worlds {
			weight += w.wt
		}
		cont, bound := opt_solve(sv, n, s, worlds, alpha - weight, beta - weight)
		return vec_shift(cont, 1), bound
	}

	seat := order[idx]

	if is_ns(seat) {
		hold := n if seat == SEAT_N else s
		if hold == 0 {
			// void follows nothing
			return opt_trick(sv, n, s, worlds, order, idx + 1, win_seat, win_rank, played, alpha, beta)
		}
		best: Vec
		have := false
		best_mean := f64(0)
		a := alpha
		m := canonical_plays(hold, FULL_SUIT & ~hold) // only distinct partner cards
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1

			nn, ss := n, s
			if seat == SEAT_N {
				nn &= ~rank_bit(r)
			} else {
				ss &= ~rank_bit(r)
			}
			ws, wr := win_seat, win_rank
			if r > win_rank {
				ws, wr = seat, r
			}
			v, _ := opt_trick(sv, nn, ss, worlds, order, idx + 1, ws, wr, played | rank_bit(r), a, beta)
			if sv.overflow {
				return Vec{}, .Exact
			}
			mn := vec_mean(v)
			if !have || mn > best_mean {
				best, best_mean, have = v, mn, true
			}
			if best_mean >= beta {
				return best, .Lower
			}
			a = max(a, best_mean)
		}
		if best_mean <= alpha {
			return best, .Upper
		}
		return best, .Exact
	}

	return opt_defender(sv, n, s, worlds, order, idx, win_seat, win_rank, seat, played, alpha, beta)
}

/*
A defender seat: minimise over the assignment of a card to each world (false-carding). Worlds where this
seat is void play nothing (one fixed group). Active worlds each choose an INTERVAL to play from (its cards
there are equals - see `opt_canonical`); worlds that play from the same interval pool into one belief for
declarer's future, and the defence wants the assignment whose groups are worth least.

BRANCH AND BOUND, NOT ENUMERATION. The assignments are a product over the worlds - 10^17 of them at the
first defender turn of KJ9 opposite A84 - so the worlds are placed one at a time (`opt_place`), each group's
value kept as it grows, and a partial placing is abandoned once it is already worth as much as the best
complete one (or as `beta`). That bound is exact because a group's value only rises as worlds join it:
another world adds its tricks to declarer's total and takes none away, whatever declarer then does.

MEMOISED TOO, not only whole tricks (`opt_solve`): the placing re-evaluates one group from many branches, and
each evaluation is this node again. The key is the node exactly - who is still to play, what is winning,
declarer's cards on the trick and the worlds.
*/
@(private)
opt_defender :: proc(
	sv: ^Opt_Solver,
	n, s: u16,
	worlds: []Opt_World,
	order: [4]int,
	idx, win_seat, win_rank, seat: int,
	played: u16,
	alpha, beta: f64,
) -> (
	Vec,
	Bound,
) {
	key := opt_defender_key(n, s, worlds, order[0], idx, is_ns(win_seat), win_rank, played)
	if e, ok := sv.memo[key]; ok && memo_answers(e, alpha, beta) {
		return e.v, e.bound
	}
	v, bound := opt_defender_search(sv, n, s, worlds, order, idx, win_seat, win_rank, seat, played, alpha, beta)
	if !sv.overflow {
		memo_store(sv, key, v, bound)
	}
	return v, bound
}

@(private)
opt_defender_search :: proc(
	sv: ^Opt_Solver,
	n, s: u16,
	worlds: []Opt_World,
	order: [4]int,
	idx, win_seat, win_rank, seat: int,
	played: u16,
	alpha, beta: f64,
) -> (
	Vec,
	Bound,
) {
	void_worlds: [dynamic]Opt_World
	void_worlds.allocator = context.temp_allocator
	Choosing :: struct {
		world: Opt_World,
		cands: u16, // one card per interval this seat holds a card in
	}
	active: [dynamic]Choosing
	active.allocator = context.temp_allocator

	for w in worlds {
		hold := w.e if seat == SEAT_E else w.w
		if hold == 0 {
			append(&void_worlds, w)
			continue
		}
		// Only declarer's cards separate a defender's: one card per interval it holds a card in.
		append(&active, Choosing{w, canonical_plays(hold, n | s | played)})
	}

	// The void group continues unchanged (nothing played, winner intact). Asked exactly: it is a term in
	// every placing's total, not a choice.
	base: Vec
	if len(void_worlds) > 0 {
		base, _ = opt_trick(sv, n, s, void_worlds[:], order, idx + 1, win_seat, win_rank, played, -INF, INF)
		if sv.overflow {
			return Vec{}, .Exact
		}
	}
	if len(active) == 0 {
		return base, .Exact
	}

	// Forced worlds first (they cost no branching and lift the bound at once), then the heaviest: the
	// worlds that move the total most are decided while the bound can still prune a lot.
	slice.sort_by(active[:], proc(a, b: Choosing) -> bool {
		fa, fb := card_count(a.cands) == 1, card_count(b.cands) == 1
		if fa != fb {return fa}
		return a.world.wt > b.world.wt
	})
	pl := Opt_Placing {
		sv       = sv,
		n        = n,
		s        = s,
		order    = order,
		idx      = idx,
		win_seat = win_seat,
		win_rank = win_rank,
		seat     = seat,
		played   = played,
		worlds   = make([]Opt_World, len(active), context.temp_allocator),
		cands    = make([]u16, len(active), context.temp_allocator),
		base     = base,
		alpha    = alpha,
		beta     = beta,
	}
	for c, i in active {
		pl.worlds[i] = c.world
		pl.cands[i] = c.cands
	}
	for g in 0 ..= RANKS {
		pl.members[g] = make([]Opt_World, len(active), context.temp_allocator)
	}
	opt_place(&pl, 0)
	switch {
	case sv.overflow:
		return Vec{}, .Exact
	case pl.low:
		return pl.best, .Upper // the defence holds declarer to `alpha` or less: enough for the caller
	case !pl.have:
		return bound_vec(beta), .Lower // no placing keeps declarer under `beta`
	}
	return pl.best, .Exact
}

// One defender node's search (`opt_defender`): the worlds placed so far in each interval's group, each
// group's value, and the best complete placing found.
@(private)
Opt_Placing :: struct {
	sv:                            ^Opt_Solver,
	n, s:                          u16,
	order:                         [4]int,
	idx, win_seat, win_rank, seat: int,
	played:                        u16,
	worlds:                        []Opt_World, // the active worlds, in placing order
	cands:                         []u16,
	members:                       [RANKS + 1][]Opt_World, // per interval: its worlds, card removed
	count:                         [RANKS + 1]int,
	shown:                         [RANKS + 1]int, // a rank from the interval: the group's card on the trick
	value:                         [RANKS + 1]Vec,
	base:                          Vec,
	alpha, beta:                   f64,
	best:                          Vec,
	best_mean:                     f64,
	have:                          bool,
	low:                           bool, // a placing at or under `alpha` was found: the search is over
}

// Place world `i` and the rest, in each interval it can play from: cheapest rise first, so the first
// complete placing is the greedy one and prunes the rest from the start.
@(private)
opt_place :: proc(pl: ^Opt_Placing, i: int) {
	sv := pl.sv
	if sv.overflow || pl.low {
		return
	}
	total := pl.base
	for g in 0 ..= RANKS {
		if pl.count[g] > 0 {
			total = vec_add(total, pl.value[g])
		}
	}
	// Worth this much already, whatever the rest do: at or over the best so far (or `beta`), stop.
	cutoff := pl.best_mean if pl.have else pl.beta
	mean := vec_mean(total)
	if mean >= cutoff {
		return
	}
	if i == len(pl.worlds) {
		pl.best, pl.best_mean, pl.have = total, mean, true
		pl.low = mean <= pl.alpha
		return
	}

	mark := virtual.arena_temp_begin(sv.scratch)
	defer virtual.arena_temp_end(mark)

	Option :: struct {
		g, r:  int,
		world: Opt_World,
		v:     Vec,
		rise:  f64,
	}
	options: [RANKS]Option
	k := 0
	sep := pl.n | pl.s | pl.played
	m := pl.cands[i]
	for m != 0 {
		r := int(intrinsics.count_trailing_zeros(m))
		m &= m - 1
		sv.budget -= 1
		if sv.budget < 0 {
			sv.overflow = true
			return
		}
		g := card_count(sep >> uint(r + 1))
		w := pl.worlds[i]
		if pl.seat == SEAT_E {
			w.e &= ~rank_bit(r)
		} else {
			w.w &= ~rank_bit(r)
		}
		// The group as it would be with this world in it. Every rank in an interval beats or loses to each of
		// declarer's cards alike, so the group's card on the trick is any member's.
		pl.members[g][pl.count[g]] = w
		shown := pl.shown[g] if pl.count[g] > 0 else r
		ws, wr := pl.win_seat, pl.win_rank
		if shown > wr {
			ws, wr = pl.seat, shown
		}
		// Only worth knowing exactly below what would already put this placing over the cutoff.
		before := vec_mean(pl.value[g]) if pl.count[g] > 0 else 0
		room := cutoff - (mean - before)
		v, bound := opt_trick(
			sv,
			pl.n,
			pl.s,
			pl.members[g][:pl.count[g] + 1],
			pl.order,
			pl.idx + 1,
			ws,
			wr,
			pl.played,
			-INF,
			room,
		)
		if sv.overflow {
			return
		}
		if bound == .Lower {
			continue // this world here puts the placing over the cutoff
		}
		options[k] = Option{g, r, w, v, vec_mean(v) - before}
		k += 1
	}
	slice.sort_by(options[:k], proc(a, b: Option) -> bool {return a.rise < b.rise})

	for o in options[:k] {
		g := o.g
		old_value, old_shown := pl.value[g], pl.shown[g]
		pl.members[g][pl.count[g]] = o.world
		if pl.count[g] == 0 {
			pl.shown[g] = o.r
		}
		pl.count[g] += 1
		pl.value[g] = o.v
		opt_place(pl, i + 1)
		pl.count[g] -= 1
		pl.value[g], pl.shown[g] = old_value, old_shown
		if sv.overflow || pl.low {
			return
		}
	}
}

@(private)
opt_defender_key :: proc(
	n, s: u16,
	worlds: []Opt_World,
	leader, idx: int,
	ns_winning: bool,
	win_rank: int,
	played: u16,
) -> u128 {
	ws := make([]Opt_World, len(worlds), context.temp_allocator)
	copy(ws, worlds)
	slice.sort_by(ws, proc(a, b: Opt_World) -> bool {
		if a.e != b.e {return a.e < b.e}
		if a.w != b.w {return a.w < b.w}
		return a.wt < b.wt
	})
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, 0xFF) // never the first byte of an `opt_canonical` key, which share the map
	put16 :: proc(b: ^strings.Builder, v: u16) {
		strings.write_byte(b, u8(v))
		strings.write_byte(b, u8(v >> 8))
	}
	put16(&b, n)
	put16(&b, s)
	put16(&b, played)
	strings.write_byte(&b, u8(leader))
	strings.write_byte(&b, u8(idx))
	strings.write_byte(&b, 1 if ns_winning else 0)
	strings.write_byte(&b, u8(win_rank + 1))
	for w in ws {
		put16(&b, w.e)
		put16(&b, w.w)
		bits := transmute(u64)w.wt
		for i in 0 ..< 8 {
			strings.write_byte(&b, u8(bits >> uint(8 * i)))
		}
	}
	return u128(xxhash.XXH3_128(b.buf[:]))
}
