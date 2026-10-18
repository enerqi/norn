#+build !js
package combo

/*
	suit_solver_table_test.odin — the self-generated suit table (suit_solver_table.odin and its baked data).

	  * a class's key, its mirror and its worst holding agree with each other;
	  * the seats swap in a lookup from the other side;
	  * DRIFT GUARD: a few entries re-solved now, at the tier each records, must match the baked table - a
	    solver or narration change without a re-bake (`just bake-suit-lines`) fails here;
	  * a class decided from its search record is decided as a search decides it;
	  * THE FLOOR: the worst holding's line, played in other members of its class, takes at least as much;
	  * the card page's override takes the table's line where its floor beats the holding's fixed line.
*/

import "core:slice"
import "core:sync"
import "core:testing"

import "../norn"

// Held by the tests that read the table and the one that turns it off (`set_suit_solver_table` is for the whole
// process): run in parallel, a lookup in one fell in the other's switched-off moment.
@(private = "file")
table_switch: sync.Mutex

@(test)
test_table_keys :: proc(t: ^testing.T) {
	// N A J 4 3, S K 9 5: from the eight up N holds A J, S holds K 9; North two small cards, South one.
	n := rank_bit(12) | rank_bit(9) | rank_bit(2) | rank_bit(1)
	s := rank_bit(11) | rank_bit(7) | rank_bit(3)
	key := solver_table_key(n, s)
	testing.expect(t, solver_table_valid(key))
	testing.expect_value(t, solver_table_mirror(solver_table_mirror(key)), key)
	testing.expect_value(t, solver_table_key(s, n), solver_table_mirror(key))
	wn, ws := solver_table_holding(key)
	testing.expect_value(t, solver_table_key(wn, ws), key)
	testing.expect_value(t, wn, rank_bit(12) | rank_bit(9) | rank_bit(0) | rank_bit(1)) // North's small: 2 3
	testing.expect_value(t, ws, rank_bit(11) | rank_bit(7) | rank_bit(2)) // South's small: the 4
}

@(test)
test_seats_swap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(
		t,
		swap_seats("Lead low from North. If East plays the K, play the A from South; if West shows out."),
		"Lead low from South. If West plays the K, play the A from North; if East shows out.",
	)
}

@(test)
test_the_table_matches_the_solver :: proc(t: ^testing.T) {
	sync.mutex_lock(&table_switch)
	defer sync.mutex_unlock(&table_switch)
	defer free_all(context.temp_allocator)
	n := len(SUIT_SOLVER_TABLE)
	if n == 0 {
		return
	}
	// Four entries found at a cheap tier, spread over the table, and the first found on a coarse class: each
	// re-solved at the tier it records (a tier-3 entry would take minutes).
	picks := make([dynamic]int, 0, 5, context.temp_allocator)
	tiers := SOLVER_TABLE_TIERS
	for want in ([?]int{0, n / 3, 2 * n / 3, n - 1}) {
		for i in want ..< n {
			if tiers[SUIT_SOLVER_TABLE[i].tier].budget <= 10_000_000 {
				append(&picks, i)
				break
			}
		}
	}
	for e, i in SUIT_SOLVER_TABLE {
		if tiers[e.tier].coarse && tiers[e.tier].budget <= 10_000_000 {
			append(&picks, i)
			break
		}
	}
	for i in picks {
		baked := SUIT_SOLVER_TABLE[i]
		e, outcome, joint := solver_table_solve(baked.key, int(baked.tier), int(baked.tier), context.temp_allocator)
		testing.expectf(t, outcome == .Entry, "class %05x no longer has a line: re-bake (just bake-suit-lines)", baked.key)
		testing.expectf(t, e.label == baked.label, "class %05x label drifted:\n  now   %q\n  baked %q", baked.key, e.label, baked.label)
		testing.expectf(t, e.tip == baked.tip, "class %05x tooltip drifted:\n  now   %q\n  baked %q", baked.key, e.tip, baked.tip)
		for k in 0 ..= RANKS {
			testing.expectf(t, abs(e.p[k] - baked.p[k]) < 1e-6, "class %05x distribution drifted at %d tricks", baked.key, k)
		}
		cells := solver_joint_cells(joint, context.temp_allocator)
		testing.expectf(
			t,
			slice.equal(cells, SUIT_SOLVER_JOINT[baked.joint_at:][:baked.joint_len]),
			"class %05x joint table drifted",
			baked.key,
		)
		marg := marginal_from_table(joint)
		for k in 0 ..= RANKS {
			testing.expectf(t, abs(marg.p[k] - f64(baked.p[k])) < 1e-6, "class %05x joint and distribution disagree at %d", baked.key, k)
		}

		// And a lookup finds it, from either side, the seats swapped from the other.
		wn, ws := solver_table_holding(baked.key)
		label, tip, _, found := solver_table_lookup(wn, ws)
		testing.expect(t, found && label == baked.label && tip == baked.tip)
		_, mtip, _, mfound := solver_table_lookup(ws, wn)
		testing.expect(t, mfound && mtip == swap_seats(baked.tip))

		// The joint table reads back as solved; from the other side, East's rows are West's.
		got, jfound := solver_table_joint(wn, ws)
		testing.expect(t, jfound && got.count == joint.count, "the stored joint table reads back")
		mirrored, mjfound := solver_table_joint(ws, wn)
		testing.expect(t, mjfound)
		for a in 0 ..= joint.m {
			testing.expect(t, mirrored.count[joint.m - a] == joint.count[a], "the mirrored joint table is East-West reversed")
		}
	}
}

/*
The worst holding's line, played in other holdings of its class, takes at least as much there: JT7
opposite AK653 is the class "N J T + 1 small, S A K + 3 small"; its worst holding gives the defenders the
6 and 7. Two members with the small cards placed otherwise are played through the card map.
*/
// A class decided again from its search record (`solver_table_replay`) is decided as a search decides it: the
// same outcome without searching, or a search from the tier it names reaching the same outcome. The bake's
// own check is wider - a bake with fixed lines removed, from records and from scratch, wrote the same table.
@(test)
test_a_class_decided_from_its_search_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tried, replayed := 0, 0
	for key in u32(0) ..< 1 << 20 {
		if tried == 60 {
			break
		}
		if !solver_table_valid(key) || solver_table_mirror(key) < key || key % 37 != 0 {
			continue
		}
		north, south := solver_table_holding(key)
		if RANKS - card_count(north | south) != 4 {
			continue
		}
		tried += 1
		rec: Solver_Search_Record
		_, want, _ := solver_table_solve(key, 0, 0, context.temp_allocator, &rec)
		got, from, search := solver_table_replay(key, rec, 0, 0)
		if search {
			_, got, _ = solver_table_solve(key, from, 0, context.temp_allocator)
		} else {
			replayed += 1
		}
		testing.expectf(t, got == want, "class %05x: %v from its record, %v searched", key, got, want)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, tried, 60)
	testing.expectf(t, replayed > 30, "only %d of %d classes decided from their records", replayed, tried)
}

@(test)
test_the_worst_holding_is_a_floor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	key := solver_table_key(0x0320, 0x181a)
	wn, ws := solver_table_holding(key)
	pol := sd_policy_make(wn, ws)
	defer sd_policy_destroy(pol)
	worst, ok := sd_policy_evaluate(pol, wn, ws, SD_POLICY_IDENTITY)
	testing.expect(t, ok, "the worst holding should solve")

	members := [][2]u16 {
		{0x0320, 0x181a}, // N J T 7, S A K 6 5 3
		{rank_bit(9) | rank_bit(8) | rank_bit(0), rank_bit(12) | rank_bit(11) | rank_bit(5) | rank_bit(4) | rank_bit(3)}, // N J T 2, S A K 7 6 5
	}
	for m in members {
		testing.expect_value(t, solver_table_key(m[0], m[1]), key)
		// The member's cards to the worst holding's: North's small cards to the bottom, then South's, then the
		// defenders', each in order.
		perm := SD_POLICY_IDENTITY
		k := 0
		for hold in ([3]u16{m[0], m[1], FULL_SUIT & ~(m[0] | m[1])}) {
			for r in 0 ..< TABLE_HIGH {
				if hold & rank_bit(r) != 0 {
					perm[r] = k
					k += 1
				}
			}
		}
		got, ok2 := sd_policy_evaluate(pol, m[0], m[1], perm)
		testing.expect(t, ok2)
		// Row by row too: each layout maps to one with East as long, so every length's tricks are a floor.
		worst_joint, _ := sd_policy_joint(pol, wn, ws, SD_POLICY_IDENTITY)
		member_joint, _ := sd_policy_joint(pol, m[0], m[1], perm)
		for a in 0 ..= worst_joint.m {
			wsum, msum: f64
			for tricks in 0 ..= RANKS {
				wsum += f64(tricks) * worst_joint.count[a][tricks]
				msum += f64(tricks) * member_joint.count[a][tricks]
			}
			testing.expectf(t, msum >= wsum, "member %04x/%04x, East with %d: under the floor", m[0], m[1], a)
		}
		testing.expectf(
			t,
			expected_tricks(got.p) >= expected_tricks(worst.p) - 1e-9,
			"member %04x/%04x takes %.4f, under the floor %.4f",
			m[0],
			m[1],
			expected_tricks(got.p),
			expected_tricks(worst.p),
		)
	}
}

@(private = "file")
holding :: proc(ranks: ..norn.Rank) -> norn.Rank_Set {
	h: norn.Rank_Set
	for r in ranks {
		h += {r}
	}
	return h
}

// A K T 6 opposite J 9 7 5 in spades: the table's floor (the king, then finesse the ten) beats the best fixed
// line, so the override is the solver's, its row the floor. (It was A J T 8 7 3 opposite 9 2 until the finesse
// lines were repaired on 2026-10-17 and a fixed line took that one.) The hearts, A K Q opposite 5 4 3, are
// a cash with nothing to override.
@(test)
test_the_override_takes_the_solver_line :: proc(t: ^testing.T) {
	sync.mutex_lock(&table_switch)
	defer sync.mutex_unlock(&table_switch)
	defer free_all(context.temp_allocator)
	north := norn.Hand_Summary {
		suits = {
			.Spades = holding(.Ace, .King, .Ten, .Six),
			.Hearts = holding(.Ace, .King, .Queen),
			.Diamonds = holding(.Four, .Three, .Two),
			.Clubs = holding(.Four, .Three, .Two),
		},
	}
	south := norn.Hand_Summary {
		suits = {
			.Spades = holding(.Jack, .Nine, .Seven, .Five),
			.Hearts = holding(.Five, .Four, .Three),
			.Diamonds = holding(.Ace, .King, .Five),
			.Clubs = holding(.Seven, .Six, .Five),
		},
	}
	sd := sd_bundle(north, south)
	ov := suit_overrides(north, south, &sd)
	label, _, floor, hit := solver_table_lookup(0x1910, 0x02a8)
	testing.expect(t, hit, "AKT6/J975 should be in the table")
	testing.expect(t, ov[0].ok && ov[0].solver, "the spades should take the solver line")
	testing.expect_value(t, ov[0].label, label)
	// The solver line is the spades' blind line now (Phase 7): its floor is the sd row, and the row the page
	// marks as the solver's.
	testing.expect_value(t, sd.best_name[0], SOLVER_LINE)
	testing.expect_value(t, ov[0].book, sd.best_marg[0].p)
	for k in 0 ..= RANKS {
		testing.expect(t, abs(sd.best_marg[0].p[k] - floor.p[k]) < 1e-6)
	}
	fixed := best_line_by_mean(0x1910, 0x02a8)
	testing.expect(t, expected_tricks(floor.p) > expected_tricks(fixed.dist.p))
	testing.expect(t, !ov[1].ok, "the hearts are a cash: no override")

	// With the table off the spades go back to the fixed line, and every total is no higher.
	set_suit_solver_table(false)
	defer set_suit_solver_table(true)
	plain := sd_bundle(north, south)
	testing.expect(t, plain.best_name[0] != SOLVER_LINE)
	testing.expect(t, expected_tricks(sd.totsd) > expected_tricks(plain.totsd), "the solver line raises the sd total")
	for k in 0 ..= RANKS {
		testing.expect(t, sd.atl[k] >= plain.atl[k] - 1e-12, "the adaptive curve is never lower with one more line")
	}
}
