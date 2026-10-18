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
import "core:mem"
import "core:mem/virtual"
import "core:slice"

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
	// themselves run to a kilobyte, and a solve can store a million of them. The distributions are kept
	// apart, in `vals` (see `Opt_Memo`).
	memo:     map[u128]Opt_Memo,
	vals:     [dynamic]f64,
	// Every node's scratch, given back when the node returns (`opt_solve`): only the memo outlives one.
	scratch:  ^mem.Arena,
	dd:       map[Suit_Layout]int, // `suit_dd_tricks`' memo, for the ceiling at each declarer node
}

/*
THE SEARCH'S SCRATCH: `mem.Arena`, a bump allocator, over one block of address space. A node takes a mark
(the arena's `offset`) and puts it back when it returns, so everything it allocated goes at once.

`virtual.Arena` with `arena_temp_begin`/`_end` did the same, but took a lock on every allocation and every
release (one solver is one thread, so nothing to lock against) and zeroed every byte given back. Measured
on the bake's own searches (2026-10-18): 8-10% of a solve. `mem.Arena` zeroes what it hands out instead,
as `.Alloc` promises, and does not lock.

Its block cannot grow, so it is sized far past need: the bake's searches used about 1 MB. It is committed
whole, which costs address space and commit charge, not memory: Windows gives a page memory when it is
first touched. Running out panics in the search (a nil allocation), it does not answer wrongly.
*/
@(private)
OPT_SCRATCH_SIZE :: 128 << 20

@(private)
opt_scratch_init :: proc(sc: ^mem.Arena) -> mem.Allocator_Error {
	data := virtual.reserve_and_commit(OPT_SCRATCH_SIZE) or_return
	mem.arena_init(sc, data)
	return nil
}

@(private)
opt_scratch_destroy :: proc(sc: ^mem.Arena) {
	if sc.data != nil {
		virtual.release(raw_data(sc.data), uint(len(sc.data)))
	}
	sc^ = {}
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
	// Each interval's missing ranks as a mask (interval `j`: the ranks with `j` of declarer's cards above
	// them), and those some defender still holds a card in, from the top.
	imask: [RANKS + 1]u16
	above := 0
	for r := RANKS - 1; r >= 0; r -= 1 {
		if sep & rank_bit(r) != 0 {
			above += 1
		} else {
			imask[above] |= rank_bit(r)
		}
	}
	held: [RANKS + 1]u16
	nh := 0
	for m in imask {
		if m & live != 0 {
			held[nh] = m
			nh += 1
		}
	}

	packed := make([]Opt_World, len(worlds), context.temp_allocator)
	for w, i in worlds {
		e, west: u16
		for m in held[:nh] {
			ce := card_count(w.e & m)
			top := top_ranks(m, ce + card_count(w.w & m))
			east := top_ranks(m, ce)
			e |= east
			west |= top & ~east
		}
		packed[i] = Opt_World{e, west, w.wt}
	}
	// Packing preserves the order of the counts (a higher interval is higher bits, more cards in it a
	// bigger number), so two positions with the same structure sort their worlds the same way.
	sort_worlds(packed)
	merged := make([dynamic]Opt_World, 0, len(packed), context.temp_allocator)
	for w in packed {
		if l := len(merged); l > 0 && merged[l - 1].e == w.e && merged[l - 1].w == w.w {
			merged[l - 1].wt += w.wt
		} else {
			append(&merged, w)
		}
	}

	// The key is written into one buffer of its exact size, then hashed: it is built for every position the
	// search reaches, and nearly all of them are memo hits, so this is most of a solve's time.
	small: [1024]u8 = ---
	need := RANKS + 1 + len(merged) * (2 * nh + 8)
	buf := small[:need] if need <= len(small) else make([]u8, need, context.temp_allocator)
	k := 0
	// The shape: declarer's cards high to low, with a mark for each interval some defender still has a
	// card in. Empty intervals vanish - the declarer cards either side of one are then equals.
	above = 0
	last := -1
	for r := RANKS - 1; r >= 0; r -= 1 {
		switch {
		case n & rank_bit(r) != 0:
			buf[k] = 'N'
			k += 1
			above += 1
		case s & rank_bit(r) != 0:
			buf[k] = 'S'
			k += 1
			above += 1
		case imask[above] & live != 0 && above != last:
			buf[k] = 'g'
			k += 1
			last = above
		}
	}
	buf[k] = '#'
	k += 1
	for w in merged {
		for m in held[:nh] {
			buf[k] = u8(card_count(w.e & m))
			buf[k + 1] = u8(card_count(w.w & m))
			k += 2
		}
		intrinsics.unaligned_store((^u64)(&buf[k]), transmute(u64)w.wt) // little-endian, as the bytes were
		k += 8
	}
	key = u128(xxhash.XXH3_128(buf[:k]))
	return merged[:], key
}

// Worlds in key order: East's cards, West's, then the weight.
@(private)
world_less :: #force_inline proc(a, b: Opt_World) -> bool {
	ka, kb := u32(a.e) << 16 | u32(a.w), u32(b.e) << 16 | u32(b.w)
	return ka < kb || (ka == kb && a.wt < b.wt)
}

// Sorted by `world_less`. A belief is a handful of worlds (four on average in a bake), where a general sort's
// set-up costs more than the sorting: an insertion sort, up to a size where that stops being true.
@(private)
sort_worlds :: proc(ws: []Opt_World) {
	if len(ws) > 32 {
		slice.sort_by(ws, world_less)
		return
	}
	for i in 1 ..< len(ws) {
		x := ws[i]
		j := i
		for j > 0 && world_less(x, ws[j - 1]) {
			ws[j] = ws[j - 1]
			j -= 1
		}
		ws[j] = x
	}
}

// The `k` highest ranks of `m` (which has at least `k`).
@(private)
top_ranks :: #force_inline proc "contextless" (m: u16, k: int) -> u16 {
	r, x := u16(0), m
	for _ in 0 ..< k {
		high := u16(0x8000) >> intrinsics.count_leading_zeros(x)
		r |= high
		x &~= high
	}
	return r
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

	scratch: mem.Arena
	if opt_scratch_init(&scratch) != nil {
		return best.dist, false
	}
	defer opt_scratch_destroy(&scratch)
	sv := Opt_Solver {
		budget  = budget,
		memo    = make(map[u128]Opt_Memo),
		scratch = &scratch,
	}
	defer delete(sv.memo)
	defer delete(sv.vals)
	defer delete(sv.dd)
	v: Vec
	{
		context.temp_allocator = mem.arena_allocator(&scratch)
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

/*
One remembered answer: its distribution is `span` values in `Opt_Solver.vals` from `off`, tricks 0 to
span - 1. No more tricks than that are left to win (`memo_span`), so the rest are zero and not kept: a
whole `Vec` is 112 bytes, and most positions in a solve are deep, with two or three tricks to go. This
entry is 8 bytes; a million of them had cost 136 MB a solve, doubled while the map grew.
*/
Opt_Memo :: struct {
	off:   u32,
	span:  u8,
	bound: Bound,
}

// How many of a distribution's values a position can make non-zero: tricks 0 to the most still to win -
// one per round while either declarer hand has a card, and the trick in progress (a defender's turn).
@(private)
memo_span :: proc "contextless" (n, s: u16) -> int {
	return min(RANKS, max(card_count(n), card_count(s)) + 1) + 1
}

@(private)
INF :: 1e300

// Does a remembered answer settle a search over this window?
@(private)
memo_answers :: proc(v: Vec, bound: Bound, alpha, beta: f64) -> bool {
	switch bound {
	case .Exact:
		return true
	case .Lower:
		return vec_mean(v) >= beta
	case .Upper:
		return vec_mean(v) <= alpha
	}
	return false
}

// A remembered answer at `key`, if there is one and it settles a search over this window.
@(private)
memo_lookup :: proc(sv: ^Opt_Solver, key: u128, alpha, beta: f64) -> (v: Vec, bound: Bound, ok: bool) {
	e, found := sv.memo[key]
	if !found {
		return
	}
	copy(v[:e.span], sv.vals[e.off:][:e.span])
	if !memo_answers(v, e.bound, alpha, beta) {
		return {}, {}, false
	}
	return v, e.bound, true
}

// Remember an answer at the position `n`/`s`; an exact one is never replaced by a bound. A key is one
// position, so a replaced answer has the same span and is rewritten where it is.
@(private)
memo_store :: proc(sv: ^Opt_Solver, key: u128, n, s: u16, v: Vec, bound: Bound) {
	v := v
	span := memo_span(n, s)
	for k in span ..= RANKS {
		assert(v[k] == 0, "a trick distribution beyond the tricks left")
	}
	if old, ok := sv.memo[key]; ok {
		if old.bound == .Exact {
			return
		}
		assert(int(old.span) == span)
		copy(sv.vals[old.off:][:span], v[:span])
		sv.memo[key] = Opt_Memo{old.off, old.span, bound}
		return
	}
	off := len(sv.vals)
	append(&sv.vals, ..v[:span])
	sv.memo[key] = Opt_Memo{u32(off), u8(span), bound}
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

	mark := sv.scratch.offset
	defer sv.scratch.offset = mark

	// Transposition memo: a hit is free (no budget spent).
	worlds, key := opt_canonical(n, s, belief)
	if v, bound, ok := memo_lookup(sv, key, alpha, beta); ok {
		return v, bound
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
		memo_store(sv, key, n, s, bound_vec(ceiling), .Upper)
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
	memo_store(sv, key, n, s, best, bound)
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
	if v, bound, ok := memo_lookup(sv, key, alpha, beta); ok {
		return v, bound
	}
	v, bound := opt_defender_search(sv, n, s, worlds, order, idx, win_seat, win_rank, seat, played, alpha, beta)
	if !sv.overflow {
		memo_store(sv, key, n, s, v, bound)
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

	mark := sv.scratch.offset
	defer sv.scratch.offset = mark

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
	// The worlds often arrive sorted (a canonical belief, or a group placed in order).
	ws := worlds
	for i in 1 ..< len(ws) {
		if world_less(ws[i], ws[i - 1]) {
			ws = slice.clone(worlds, context.temp_allocator)
			sort_worlds(ws)
			break
		}
	}
	// Written into one buffer of its exact size, then hashed (see `opt_canonical`).
	small: [1024]u8 = ---
	need := 11 + 12 * len(ws)
	buf := small[:need] if need <= len(small) else make([]u8, need, context.temp_allocator)
	buf[0] = 0xFF // never the first byte of an `opt_canonical` key, which share the map
	intrinsics.unaligned_store((^u16)(&buf[1]), n) // little-endian, as all of it
	intrinsics.unaligned_store((^u16)(&buf[3]), s)
	intrinsics.unaligned_store((^u16)(&buf[5]), played)
	buf[7] = u8(leader)
	buf[8] = u8(idx)
	buf[9] = 1 if ns_winning else 0
	buf[10] = u8(win_rank + 1)
	k := 11
	for w in ws {
		intrinsics.unaligned_store((^u16)(&buf[k]), w.e)
		intrinsics.unaligned_store((^u16)(&buf[k + 2]), w.w)
		intrinsics.unaligned_store((^u64)(&buf[k + 4]), transmute(u64)w.wt)
		k += 12
	}
	key := u128(xxhash.XXH3_128(buf))
	return key
}

