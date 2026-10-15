package combo

/*
	single_dummy_policy.odin — Phase 3 of the suit solver: the optimal search's LINE, not only its number,
	and what that line is really worth.

	WHY A LINE NEEDS ITS OWN VALUE. `opt_solve` (single_dummy_opt.odin) lets the defence choose a whole
	false-carding scheme first - which layouts show which card - and lets declarer answer each group KNOWING
	that scheme. A declarer at the table cannot know it: their line is a fixed rule from what they have seen
	to what they play, and the defence, seeing the deal, may then play each layout whichever way beats that
	rule. Against a fixed line the defence's choices no longer interact (declarer's reply depends only on
	the cards shown), so the best defence is chosen layout by layout, and the line's value is a plain
	double-dummy walk per layout. That value is never above the search's, and is the one a table may print.

	THE LINE (`Sd_Policy`) is a tree over what declarer has seen. At each declarer turn it holds the card
	played; at each defender turn, one branch per interval the card shown came from (or `shows out`). The
	card at a declarer turn is the optimal search's choice over the layouts still CONSISTENT with what has
	been seen - every layout that could have produced it, whatever the defence's scheme. Nodes are built
	when first reached, so only the part of the tree some layout can reach exists.

	A LINE FROM ANOTHER HOLDING. The tree may be built over a SIMPLER holding than the one it is played in
	(`sd_policy_evaluate`'s `perm`): ranks are mapped one to one, and the line is followed through the map.
	Relabelling the small spots so the defenders' small cards are higher and contiguous makes a holding far
	cheaper to search; the line it gives is then played, and valued, in the real holding.
*/

import "base:intrinsics"
import "core:mem"
import "core:mem/virtual"

// The interval a defender showing out is filed under.
@(private)
POLICY_VOID :: RANKS + 1

Policy_Node :: struct {
	// The position, in the policy's ranks: declarer's cards, declarer's cards on this trick, the play order,
	// how many cards are on the trick (0 = declarer to lead), and what is winning it.
	n, s, played:            u16,
	order:                   [4]int,
	idx, win_seat, win_rank: int,
	// Every layout consistent with what declarer has seen, with its a-priori weight.
	worlds:                  []Opt_World,
	// A declarer turn: the card chosen (`decided` once the search has run).
	decided:                 bool,
	hand, rank:              int,
	value:                   Vec, // the search's value of that card over `worlds`
	next:                    ^Policy_Node,
	// A defender turn: the position after a card from each interval (`POLICY_VOID` = shows out).
	branches:                [RANKS + 2]^Policy_Node,
}

Sd_Policy :: struct {
	north, south: u16,
	root:         ^Policy_Node,
	solver:       Opt_Solver,
	scratch:      virtual.Arena, // the search's per-node scratch
	nodes:        virtual.Arena, // the tree
	overflow:     bool,
}

// A policy over `north`/`south` (in the ranks it will be searched in). Free it with `sd_policy_destroy`.
sd_policy_make :: proc(north, south: u16, budget := DEFAULT_OPT_BUDGET) -> ^Sd_Policy {
	pol := new(Sd_Policy)
	pol.north, pol.south = north, south
	_ = virtual.arena_init_growing(&pol.scratch)
	_ = virtual.arena_init_growing(&pol.nodes)
	pol.solver = Opt_Solver {
		budget  = budget,
		memo    = make(map[u128]Opt_Memo),
		scratch = &pol.scratch,
	}
	alloc := virtual.arena_allocator(&pol.nodes)
	pol.root = new(Policy_Node, alloc)
	pol.root.n, pol.root.s = north, south
	pol.root.worlds = initial_worlds(north, south, alloc)
	return pol
}

sd_policy_destroy :: proc(pol: ^Sd_Policy) {
	delete(pol.solver.memo)
	delete(pol.solver.dd)
	virtual.arena_destroy(&pol.scratch)
	virtual.arena_destroy(&pol.nodes)
	free(pol)
}

// Every E/W split of the cards NS lack, with its vacant-space weight (as `sd_optimal_distribution`).
@(private)
initial_worlds :: proc(north, south: u16, allocator: mem.Allocator) -> []Opt_World {
	missing := FULL_SUIT & ~(north | south)
	m := card_count(missing)
	worlds := make([dynamic]Opt_World, 0, 1 << uint(m), allocator)
	east := missing
	for {
		append(&worlds, Opt_World{e = east, w = missing & ~east, wt = g_binom[26 - m][13 - card_count(east)]})
		if east == 0 {
			break
		}
		east = (east - 1) & missing
	}
	return worlds[:]
}

// The declarer card at `node`: the search's best over the consistent layouts. False once over budget.
@(private)
policy_decide :: proc(pol: ^Sd_Policy, node: ^Policy_Node) -> bool {
	if node.decided {
		return true
	}
	sv := &pol.solver
	context.temp_allocator = virtual.arena_allocator(&pol.scratch)
	mark := virtual.arena_temp_begin(&pol.scratch)
	defer virtual.arena_temp_end(mark)

	// Searched over the merged layouts, as `opt_solve` searches: unmerged, a defender turn places every one
	// separately. Mid-trick, declarer's cards on the trick still separate the defenders' (`opt_canonical`
	// is given them as declarer's).
	worlds, _ := opt_canonical(node.n | node.played, node.s, node.worlds)

	have := false
	best_mean := f64(0)
	a := f64(-INF)
	try :: proc(
		node: ^Policy_Node,
		hand, r: int,
		v: Vec,
		bound: Bound,
		have: ^bool,
		best_mean, a: ^f64,
	) {
		mn := vec_mean(v)
		if bound != .Upper && (!have^ || mn > best_mean^) {
			node.hand, node.rank, node.value = hand, r, v
			best_mean^, have^ = mn, true
			a^ = max(a^, mn)
		}
	}
	if node.idx == 0 {
		live := node.n | node.s
		for w in worlds {
			live |= w.e | w.w
		}
		for hand in ([2]int{SEAT_N, SEAT_S}) {
			hold := node.n if hand == SEAT_N else node.s
			if hold == 0 {
				continue
			}
			m := canonical_plays(hold, live & ~hold)
			for m != 0 {
				r := int(intrinsics.count_trailing_zeros(m))
				m &= m - 1
				nn, ss := node.n, node.s
				if hand == SEAT_N {nn &= ~rank_bit(r)} else {ss &= ~rank_bit(r)}
				order := [4]int{hand, (hand + 1) % 4, (hand + 2) % 4, (hand + 3) % 4}
				v, bound := opt_trick(sv, nn, ss, worlds, order, 1, hand, r, rank_bit(r), a, INF)
				if sv.overflow {
					return false
				}
				try(node, hand, r, v, bound, &have, &best_mean, &a)
			}
		}
	} else {
		seat := node.order[node.idx]
		hold := node.n if seat == SEAT_N else node.s
		m := canonical_plays(hold, FULL_SUIT & ~hold)
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1
			nn, ss := node.n, node.s
			if seat == SEAT_N {nn &= ~rank_bit(r)} else {ss &= ~rank_bit(r)}
			ws, wr := node.win_seat, node.win_rank
			if r > wr {
				ws, wr = seat, r
			}
			v, bound := opt_trick(sv, nn, ss, worlds, node.order, node.idx + 1, ws, wr, node.played | rank_bit(r), a, INF)
			if sv.overflow {
				return false
			}
			try(node, seat, r, v, bound, &have, &best_mean, &a)
		}
	}
	node.decided = true
	return true
}

// The position after `node`'s seat plays `r` (or nothing: `r` < 0), the layouts reduced to `worlds`.
// The fourth card ends the trick: the child is declarer to lead.
@(private)
policy_child :: proc(pol: ^Sd_Policy, node: ^Policy_Node, seat, r: int, worlds: []Opt_World) -> ^Policy_Node {
	c := new(Policy_Node, virtual.arena_allocator(&pol.nodes))
	c.n, c.s, c.worlds = node.n, node.s, worlds
	if node.idx == 0 {
		c.order = {seat, (seat + 1) % 4, (seat + 2) % 4, (seat + 3) % 4}
		c.idx, c.win_seat, c.win_rank = 1, seat, r
	} else {
		c.order, c.idx, c.win_seat, c.win_rank = node.order, node.idx + 1, node.win_seat, node.win_rank
		if r >= 0 && r > c.win_rank {
			c.win_seat, c.win_rank = seat, r
		}
	}
	if is_ns(seat) && r >= 0 {
		if seat == SEAT_N {c.n &= ~rank_bit(r)} else {c.s &= ~rank_bit(r)}
	}
	c.played = node.played if node.idx > 0 else 0
	if is_ns(seat) && r >= 0 {
		c.played |= rank_bit(r)
	}
	if c.idx == 4 {
		c.idx, c.played, c.order, c.win_seat, c.win_rank = 0, 0, {}, 0, 0
	}
	return c
}

// After a declarer turn: the chosen card's position (a void seat passes).
@(private)
policy_next :: proc(pol: ^Sd_Policy, node: ^Policy_Node) -> ^Policy_Node {
	if node.next == nil {
		r := node.rank
		seat := node.hand if node.idx == 0 else node.order[node.idx]
		if node.idx > 0 && !node.decided {
			r = -1 // void: nothing played
		}
		node.next = policy_child(pol, node, seat, r, node.worlds)
	}
	return node.next
}

// A defender turn: the position after a card from interval `g` (or showing out), over the layouts that
// could have shown it.
@(private)
policy_branch :: proc(pol: ^Sd_Policy, node: ^Policy_Node, g: int) -> ^Policy_Node {
	if node.branches[g] != nil {
		return node.branches[g]
	}
	seat := node.order[node.idx]
	sep := node.n | node.s | node.played
	alloc := virtual.arena_allocator(&pol.nodes)
	worlds := make([dynamic]Opt_World, 0, len(node.worlds), alloc)
	shown := -1
	for w in node.worlds {
		hold := w.e if seat == SEAT_E else w.w
		if g == POLICY_VOID {
			if hold == 0 {
				append(&worlds, w)
			}
			continue
		}
		m := canonical_plays(hold, sep)
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1
			if card_count(sep >> uint(r + 1)) != g {
				continue
			}
			x := w
			if seat == SEAT_E {x.e &= ~rank_bit(r)} else {x.w &= ~rank_bit(r)}
			append(&worlds, x)
			shown = r
			break
		}
	}
	node.branches[g] = policy_child(pol, node, seat, shown, worlds[:])
	return node.branches[g]
}

/*
THE LINE'S VALUE in a holding: its trick distribution against the best defence, which answers it layout by
layout. `north`/`south` are the holding played in; `perm` maps each of its ranks to the policy's (the
identity when the policy was built over this holding). False when building the line ran over the budget.
*/
sd_policy_evaluate :: proc(pol: ^Sd_Policy, north, south: u16, perm: [RANKS]int) -> (dist: Suit_Trick_Dist, ok: bool) {
	ev := Policy_Eval {
		pol  = pol,
		perm = perm,
		memo = make(map[Eval_Key]int),
	}
	defer delete(ev.memo)
	for r in 0 ..< RANKS {
		ev.inv[perm[r]] = r
	}
	dist.max_tricks = card_count(north | south)
	worlds := initial_worlds(north, south, context.temp_allocator)
	denom := g_binom[26][13]
	for w in worlds {
		t := policy_eval(&ev, pol.root, w.e, w.w, 0, -1)
		if pol.overflow {
			return {}, false
		}
		dist.p[t] += w.wt / denom
	}
	return dist, true
}

/*
The line's value as a JOINT table: `count[a][k]` is the number of layouts where East holds `a` of the
missing cards and the line, against the best defence there, takes `k` tricks - the shape of
`sd_line_joint_table`, which the joint DP of combine.odin folds across the four suits. Its marginal is
`sd_policy_evaluate`'s distribution. False when building the line ran over the budget.
*/
sd_policy_joint :: proc(pol: ^Sd_Policy, north, south: u16, perm: [RANKS]int) -> (tbl: Suit_Joint_Table, ok: bool) {
	ev := Policy_Eval {
		pol  = pol,
		perm = perm,
		memo = make(map[Eval_Key]int),
	}
	defer delete(ev.memo)
	for r in 0 ..< RANKS {
		ev.inv[perm[r]] = r
	}
	tbl.ns_len = card_count(north | south)
	tbl.m = RANKS - tbl.ns_len
	for w in initial_worlds(north, south, context.temp_allocator) {
		t := policy_eval(&ev, pol.root, w.e, w.w, 0, -1)
		if pol.overflow {
			return {}, false
		}
		tbl.count[card_count(w.e)][t] += 1
	}
	return tbl, true
}

// The search's own value of the line: its value with the defence's scheme known to declarer (see the
// header). False when that search ran over the budget.
sd_policy_search_value :: proc(pol: ^Sd_Policy) -> (dist: Suit_Trick_Dist, ok: bool) {
	if !policy_decide(pol, pol.root) {
		pol.overflow = true
		return {}, false
	}
	dist.max_tricks = card_count(pol.north | pol.south)
	denom := g_binom[26][13]
	for k in 0 ..= RANKS {
		dist.p[k] = pol.root.value[k] / denom
	}
	return dist, true
}

// The identity rank map.
SD_POLICY_IDENTITY :: [RANKS]int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}

@(private)
Eval_Key :: struct {
	node:               ^Policy_Node,
	e, w:               u16,
	win_seat, win_rank: i8,
}

@(private)
Policy_Eval :: struct {
	pol:       ^Sd_Policy,
	perm, inv: [RANKS]int,
	memo:      map[Eval_Key]int,
}

@(private)
unmap_mask :: proc(ev: ^Policy_Eval, m: u16) -> u16 {
	r: u16
	for k in 0 ..< RANKS {
		if m & rank_bit(k) != 0 {
			r |= rank_bit(ev.inv[k])
		}
	}
	return r
}

// The tricks declarer takes from `node` on, in the real layout `e`/`w`, against its best defence. The
// trick in progress is being won by `win_seat` with the real rank `win_rank`.
@(private)
policy_eval :: proc(ev: ^Policy_Eval, node: ^Policy_Node, e, w: u16, win_seat, win_rank: int) -> int {
	pol := ev.pol
	if pol.overflow {
		return 0
	}
	if node.idx == 0 && node.n == 0 && node.s == 0 {
		return 0
	}
	key := Eval_Key{node, e, w, i8(win_seat), i8(win_rank)}
	if t, ok := ev.memo[key]; ok {
		return t
	}

	// The card just played went to `win`: the trick ends after the fourth.
	step :: proc(ev: ^Policy_Eval, from, to: ^Policy_Node, e, w: u16, ws, wr: int) -> int {
		if from.idx == 3 {
			return (1 if is_ns(ws) else 0) + policy_eval(ev, to, e, w, 0, -1)
		}
		return policy_eval(ev, to, e, w, ws, wr)
	}

	t := 0
	seat := node.order[node.idx] if node.idx > 0 else -1
	switch {
	case node.idx == 0 || is_ns(seat):
		hold := node.n if seat == SEAT_N else node.s
		if node.idx > 0 && hold == 0 {
			t = step(ev, node, policy_next(pol, node), e, w, win_seat, win_rank)
			break
		}
		if !policy_decide(pol, node) {
			pol.overflow = true
			return 0
		}
		r := ev.inv[node.rank]
		ws, wr := win_seat, win_rank
		if node.idx == 0 {
			ws, wr = node.hand, r
		} else if r > wr {
			ws, wr = seat, r
		}
		t = step(ev, node, policy_next(pol, node), e, w, ws, wr)
	case:
		hold := e if seat == SEAT_E else w
		if hold == 0 {
			t = step(ev, node, policy_branch(pol, node, POLICY_VOID), e, w, win_seat, win_rank)
			break
		}
		// Declarer's real cards still out, plus those on this trick, separate the defender's real cards.
		sep := unmap_mask(ev, node.n | node.s | node.played)
		psep := node.n | node.s | node.played
		t = max(int)
		m := canonical_plays(hold, sep)
		for m != 0 {
			r := int(intrinsics.count_trailing_zeros(m))
			m &= m - 1
			g := card_count(psep >> uint(ev.perm[r] + 1))
			ne, nw := e, w
			if seat == SEAT_E {ne &= ~rank_bit(r)} else {nw &= ~rank_bit(r)}
			ws, wr := win_seat, win_rank
			if r > wr {
				ws, wr = seat, r
			}
			x := step(ev, node, policy_branch(pol, node, g), ne, nw, ws, wr)
			if pol.overflow {
				return 0
			}
			t = min(t, x)
		}
	}
	ev.memo[key] = t
	return t
}

/*
THE SMALL SPOTS RELABELLED: a rank map from a holding to a simpler one, for `sd_certified_line`. Among the
ranks below `below` (a rank index: 6 = the cards below the eight), declarer's cards are moved to the bottom,
in order, and the defenders' to the top of that range. The defenders' small cards then lie in ONE interval,
so the layouts that differ only in them merge, and a holding whose search does not finish often does
relabelled. It is neither a lower nor an upper bound on the holding - small cards do win tricks - which is
why the line it gives is valued back in the real holding rather than trusted.
*/
small_spot_perm :: proc(north, south: u16, below: int) -> (perm: [RANKS]int) {
	perm = SD_POLICY_IDENTITY
	k := 0
	for r in 0 ..< below {
		if (north | south) & rank_bit(r) != 0 {
			perm[r] = k
			k += 1
		}
	}
	for r in 0 ..< below {
		if (north | south) & rank_bit(r) == 0 {
			perm[r] = k
			k += 1
		}
	}
	return
}

// `m`'s ranks moved through `perm`.
perm_mask :: proc(m: u16, perm: [RANKS]int) -> u16 {
	r: u16
	for k in 0 ..< RANKS {
		if m & rank_bit(k) != 0 {
			r |= rank_bit(perm[k])
		}
	}
	return r
}

// Where a certified line came from.
Line_Source :: enum u8 {
	Fixed, // brick 2's best fixed line: nothing found beat it
	Search, // the optimal search over the holding itself
	Relabel, // the search over the holding with its small spots relabelled (`small_spot_perm`)
}

// Below the eight: measured over 400 holdings, the coarsest relabel that loses almost nothing (below the
// nine lost up to 1.3 tricks).
SMALL_SPOTS_BELOW :: 6

Sd_Certified :: struct {
	dist:    Suit_Trick_Dist, // the line's value against the best defence (`sd_policy_evaluate`)
	source:  Line_Source,
	// Proven best: no line takes more on average. The search's own value bounds every line from above,
	// and this one reaches it (or the fixed line reaches the double-dummy census).
	optimal: bool,
	policy:  ^Sd_Policy, // the line (nil for `.Fixed`); free with `sd_certified_destroy`
	// The search over the holding itself finished within the budget: a `.Fixed` result is then the search's
	// verdict, not a search that gave up (a bake escalates only the latter).
	searched: bool,
	perm:    [RANKS]int, // the holding's ranks to the policy's
}

sd_certified_destroy :: proc(c: ^Sd_Certified) {
	if c.policy != nil {
		sd_policy_destroy(c.policy)
		c.policy = nil
	}
}

/*
THE BEST LINE WHOSE VALUE IS GUARANTEED, for an offline table: brick 2's best fixed line, the optimal
search's line, or - when that search does not finish, or its line falls short of its own value - the line
searched with the small spots relabelled. Every candidate is valued the same way, against the best defence
in the real holding, and the best is kept. Measured over 400 holdings with 3-8 cards missing (2026-10-14):
304 have a searched line, 123 beat the best fixed line (by 0.16 trick on average), and where the search's
line is valued it equals the search's own (optimistic) value in 169 of 193.
*/
sd_certified_line :: proc(north, south: u16, budget := DEFAULT_OPT_BUDGET) -> (best: Sd_Certified) {
	fixed := best_line_by_mean(north, south)
	best.dist, best.source = fixed.dist, .Fixed
	census := expected_tricks(suit_trick_distribution(north, south).p)
	if expected_tricks(fixed.dist.p) >= census - 1e-9 {
		best.optimal, best.searched = true, true
		return
	}
	EPS :: 1e-9
	consider :: proc(best: ^Sd_Certified, pol: ^Sd_Policy, dist: Suit_Trick_Dist, source: Line_Source, perm: [RANKS]int) -> bool {
		if expected_tricks(dist.p) <= expected_tricks(best.dist.p) + EPS {
			return false
		}
		sd_certified_destroy(best)
		best.dist, best.source, best.policy, best.perm, best.optimal = dist, source, pol, perm, false
		return true
	}

	own := sd_policy_make(north, south, budget)
	search, own_ok := sd_policy_search_value(own)
	if own_ok {
		if dist, ok := sd_policy_evaluate(own, north, south, SD_POLICY_IDENTITY); ok {
			if !consider(&best, own, dist, .Search, SD_POLICY_IDENTITY) {
				sd_policy_destroy(own)
			}
		} else {
			sd_policy_destroy(own)
			own_ok = false
		}
	} else {
		sd_policy_destroy(own)
	}
	best.searched = own_ok
	if own_ok && expected_tricks(best.dist.p) >= expected_tricks(search.p) - EPS {
		best.optimal = true
		return
	}

	perm := small_spot_perm(north, south, SMALL_SPOTS_BELOW)
	if perm != SD_POLICY_IDENTITY {
		rel := sd_policy_make(perm_mask(north, perm), perm_mask(south, perm), budget)
		if dist, ok := sd_policy_evaluate(rel, north, south, perm); !ok || !consider(&best, rel, dist, .Relabel, perm) {
			sd_policy_destroy(rel)
		}
	}
	best.optimal = own_ok && expected_tricks(best.dist.p) >= expected_tricks(search.p) - EPS
	return
}
