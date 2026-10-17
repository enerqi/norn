package combo

/*
	suit_solver_table.odin — Phase 5 of the suit solver: the self-generated suit-combination TABLE.

	The solver is too slow to run while a page is written (a line takes about half a second), so its lines
	are baked offline (`just bake-suit-lines`, cmd/bake_suit_lines.odin) into `SUIT_SOLVER_TABLE`
	(suit_solver_table_data.odin, generated) and looked up here.

	ONE ENTRY PER CLASS OF HOLDINGS, not per holding: two holdings are in one class when they agree on who
	holds each card from the eight up and on how many cards below the eight each hand holds. Which small
	cards those are is left out, as a book writes them `x`. That is 3^7 x 28 classes against 3^13 holdings,
	and the line is the same for the whole class.

	THE CLASS'S HOLDING IS ITS WORST (`solver_table_holding`): the defenders hold the highest small cards,
	North's small cards are the lowest. The entry is that holding's certified line (`sd_certified_line`),
	and its value there is a FLOOR for every member: played in any member through the obvious card map, each
	trick declarer wins in the worst holding is won there too (a small card of declarer's that wins beats
	defenders' small cards that are higher in the worst holding), and the defenders see the same choices. So
	the table's chances read "at least", and a member may do better.

	The table holds a class only where its line beats the best fixed line in that worst holding. North and
	South are symmetric: a class is stored once, by its smaller key, and a lookup from the other side swaps
	the seats named in the words (North and South, East and West).

	TIERS (`SOLVER_TABLE_TIERS`). A class is searched at a growing budget until the search finishes; past
	the largest, its COARSE class is tried - the same holding with the eight counted as a small card too
	(`small_spot_perm` below the nine). The coarse class's worst holding is worse still, so its line, valued
	there, is still a floor for every member; it is narrated naming nothing below the nine. Measured on the
	classes that do not finish at 3*10^6 (2026-10-15): 41% finish by 10^8, and the coarse fallback brings that
	to 65%; 31% then beat the fixed line, by 0.09 trick on average.

	THE JOINT TABLE. Each entry also keeps its line's value split by East's length (`solver_table_joint`):
	the shape the fixed lines have (`sd_line_joint_table`), so the line joins them as one more CANDIDATE in
	the joint DP that gives the sd totals and the adaptive curve, and in the page's a-posteriori re-pick
	(`gather_candidate_tables`, Phase 7). The floor argument holds layout by layout, and the card map keeps
	each defender's length, so each row of it is a floor too. Stored as `SUIT_SOLVER_JOINT` cells, one u16
	each: East's length (4 bits), tricks (4 bits), layouts (7 bits; at most C(9,4) = 126 with nine missing).
*/

import "core:math"
import "core:slice"
import "core:strings"

Solver_Table_Entry :: struct {
	key:   u32,
	tier:  u8, // the `SOLVER_TABLE_TIERS` entry whose search found the line
	p:     [RANKS + 1]f32, // the trick distribution of the worst holding, a floor for the class
	label: string,
	tip:   string,
	// This entry's cells of `SUIT_SOLVER_JOINT` (see the header): `joint_len` of them from `joint_at`.
	joint_at:  u32,
	joint_len: u8,
}

Solver_Table_Tier :: struct {
	budget: int,
	coarse: bool, // the coarse class: the eight counted as a small card too
}

// The budgets a class is searched at, in order, until one finishes; then its coarse class.
SOLVER_TABLE_TIERS :: [?]Solver_Table_Tier {
	{3_000_000, false},
	{10_000_000, false},
	{30_000_000, false},
	{100_000_000, false},
	{3_000_000, true},
	{10_000_000, true},
}

// The coarse class's cut: its small cards are those below the nine.
@(private)
COARSE_BELOW :: 7

// What the bake found for a class.
Solver_Table_Outcome :: enum u8 {
	Entry, // a line better than the fixed one
	No_Gain, // a search finished, and found nothing better than the fixed line
	Out_Of_Budget, // no tier's search finished
}

// The highest small spot: the class's cards from here up are kept, those below it are counted.
@(private)
TABLE_HIGH :: SMALL_SPOTS_BELOW

/*
THE CLASS KEY of a holding: two bits per card from the eight up (0 missing, 1 North, 2 South), then
North's and South's counts of cards below the eight, three bits each.
*/
solver_table_key :: proc(north, south: u16) -> u32 {
	key: u32
	for r in TABLE_HIGH ..< RANKS {
		owner: u32
		switch {
		case north & rank_bit(r) != 0:
			owner = 1
		case south & rank_bit(r) != 0:
			owner = 2
		}
		key |= owner << uint(2 * (r - TABLE_HIGH))
	}
	small := rank_bit(TABLE_HIGH) - 1
	key |= u32(card_count(north & small)) << 14
	key |= u32(card_count(south & small)) << 17
	return key
}

// The same class with North and South exchanged.
solver_table_mirror :: proc(key: u32) -> u32 {
	m: u32
	for i in 0 ..< RANKS - TABLE_HIGH {
		owner := key >> uint(2 * i) & 3
		if owner != 0 {
			owner = 3 - owner
		}
		m |= owner << uint(2 * i)
	}
	m |= (key >> 17 & 7) << 14
	m |= (key >> 14 & 7) << 17
	return m
}

// The class's worst holding: North's small cards lowest, then South's, the defenders' above both.
solver_table_holding :: proc(key: u32) -> (north, south: u16) {
	for i in 0 ..< RANKS - TABLE_HIGH {
		switch key >> uint(2 * i) & 3 {
		case 1:
			north |= rank_bit(TABLE_HIGH + i)
		case 2:
			south |= rank_bit(TABLE_HIGH + i)
		}
	}
	a, b := int(key >> 14 & 7), int(key >> 17 & 7)
	for r in 0 ..< a {
		north |= rank_bit(r)
	}
	for r in a ..< a + b {
		south |= rank_bit(r)
	}
	return
}

// Is `key` a class: at most six small cards between the hands, and no owner code 3?
solver_table_valid :: proc(key: u32) -> bool {
	for i in 0 ..< RANKS - TABLE_HIGH {
		if key >> uint(2 * i) & 3 == 3 {
			return false
		}
	}
	return int(key >> 14 & 7) + int(key >> 17 & 7) <= TABLE_HIGH && key >> 20 == 0
}

/*
The entry for a class, computed: the worst holding's certified line, narrated for the class, searched at each
tier from `first` to `last` of `SOLVER_TABLE_TIERS` until a search finishes. An entry only when that line
beats the best fixed line in the class's worst holding. The bake calls this for every class over all the
tiers; the drift-guard test calls it at the one tier an entry records. `joint` is the entry's line as a
joint table (`sd_policy_joint`), in the holding its search ran on.
*/
solver_table_solve :: proc(
	key: u32,
	first := 0,
	last := len(SOLVER_TABLE_TIERS) - 1,
	allocator := context.allocator,
) -> (
	entry: Solver_Table_Entry,
	outcome: Solver_Table_Outcome,
	joint: Suit_Joint_Table,
) {
	north, south := solver_table_holding(key)
	fixed := expected_tricks(best_line_by_mean(north, south).dist.p)
	tiers := SOLVER_TABLE_TIERS
	outcome = .Out_Of_Budget
	for tier in first ..= last {
		t := tiers[tier]
		n, s := north, south
		below := TABLE_HIGH
		if t.coarse {
			perm := small_spot_perm(north, south, COARSE_BELOW)
			n, s, below = perm_mask(north, perm), perm_mask(south, perm), COARSE_BELOW
		}
		c := sd_certified_line(n, s, t.budget)
		defer sd_certified_destroy(&c)
		if !c.searched {
			continue
		}
		outcome = .No_Gain
		if c.source == .Fixed || expected_tricks(c.dist.p) <= fixed + 1e-9 {
			return
		}
		label, tip, narrated := sd_narrate(&c, n, s, class_below = below)
		if !narrated {
			return
		}
		tbl, joint_ok := sd_policy_joint(c.policy, n, s, c.perm)
		if !joint_ok {
			return // the line was built once already, so this does not happen
		}
		entry.key, entry.tier = key, u8(tier)
		for k in 0 ..= RANKS {
			entry.p[k] = f32(c.dist.p[k])
		}
		entry.label = strings.clone(label, allocator)
		entry.tip = strings.clone(tip, allocator)
		return entry, .Entry, tbl
	}
	return
}

// A joint table as `SUIT_SOLVER_JOINT` cells (see the header), its non-zero counts in order.
solver_joint_cells :: proc(tbl: Suit_Joint_Table, allocator := context.allocator) -> []u16 {
	cells := make([dynamic]u16, 0, 32, allocator)
	for a in 0 ..= tbl.m {
		for k in 0 ..= tbl.ns_len {
			c := int(tbl.count[a][k])
			if c == 0 {
				continue
			}
			assert(c < 128, "a joint cell holds at most 127 layouts")
			append(&cells, u16(a << 11 | k << 7 | c))
		}
	}
	return cells[:]
}

// The class's entry for a holding, and whether it is stored the other way round (North and South exchanged).
@(private)
solver_table_find :: proc(north, south: u16) -> (e: ^Solver_Table_Entry, mirrored: bool, ok: bool) {
	if g_solver_table_off {
		return
	}
	key := solver_table_key(north, south)
	stored := min(key, solver_table_mirror(key))
	i, found := slice.binary_search_by(SUIT_SOLVER_TABLE[:], stored, proc(e: Solver_Table_Entry, k: u32) -> slice.Ordering {
		return slice.cmp(e.key, k)
	})
	if !found {
		return
	}
	return &SUIT_SOLVER_TABLE[i], stored != key, true
}

/*
The table's line for a holding as a joint table (`count[a][k]`: East holds `a`, the line takes `k`), a floor
row by row. False when the table has no line for its class. Stored the other way round, the stored East is
this holding's West, so the rows are read from the other end.
*/
solver_table_joint :: proc(north, south: u16) -> (tbl: Suit_Joint_Table, ok: bool) {
	e, mirrored := solver_table_find(north, south) or_return
	tbl.ns_len = card_count(north | south)
	tbl.m = RANKS - tbl.ns_len
	for cell in SUIT_SOLVER_JOINT[e.joint_at:][:e.joint_len] {
		a, k, c := int(cell >> 11), int(cell >> 7 & 15), f64(cell & 127)
		if mirrored {
			a = tbl.m - a
		}
		tbl.count[a][k] = c
	}
	return tbl, true
}

@(private)
g_solver_table_off: bool

/*
Turn the table off (or back on) for this process. It is on by default, in the wasm player too (its page
carries the table gzipped). Set it before any analysis starts: it is not synchronised.
*/
set_suit_solver_table :: proc(on: bool) {
	g_solver_table_off = !on
}

/*
The table's line for a holding: its label and tooltip (seats as this holding has them) and the trick
distribution that is a floor for it. False when the table has no line for its class.
*/
solver_table_lookup :: proc(
	north, south: u16,
	allocator := context.temp_allocator,
) -> (
	label, tip: string,
	floor: Suit_Trick_Dist,
	ok: bool,
) {
	e, mirrored := solver_table_find(north, south) or_return
	floor.max_tricks = card_count(north | south)
	for k in 0 ..= RANKS {
		// Rounded: an f32 widened prints as 0.03913043066859245 in the page's JSON.
		floor.p[k] = math.round(f64(e.p[k]) * 1e6) / 1e6
	}
	if !mirrored {
		return e.label, e.tip, floor, true
	}
	return e.label, swap_seats(e.tip, allocator), floor, true
}

// `text` with North and South, and East and West, exchanged.
@(private)
swap_seats :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	SWAPS :: [4][2]string{{"North", "South"}, {"South", "North"}, {"East", "West"}, {"West", "East"}}
	rest := text
	outer: for len(rest) > 0 {
		for sw in SWAPS {
			if strings.has_prefix(rest, sw[0]) {
				strings.write_string(&b, sw[1])
				rest = rest[len(sw[0]):]
				continue outer
			}
		}
		strings.write_byte(&b, rest[0])
		rest = rest[1:]
	}
	return strings.to_string(b)
}
