package combo

/*
	line_probe.odin — a holding played layout by layout: the exact single-dummy optimum against the fixed lines
	(`just combo-line-probe`, `cmd/line_probe.odin`).

	`just combo-line-sweep` says WHICH holdings the fixed lines fall short on; this says WHERE: every layout of
	the missing cards (one per equivalence class), the tricks the optimal policy takes there and the tricks each
	named line takes. The layouts where a line falls short are where to trace it. It found both repairs of
	2026-10-18 at once: `finesse-high` (the deep finesse taken a second time, East's K T) and the discovery play
	(a bare queen left with West after East showed out).
*/

import "core:fmt"
import "core:strings"

// Writes one line per layout to `b`: West's and East's cards, the optimum's tricks, then each line's. Only the
// layouts where some named line differs from the optimum when `diff_only`. False when the optimal search ran
// over its budget.
line_probe :: proc(b: ^strings.Builder, north, south: u16, names: []string, diff_only := true) -> bool {
	pol := sd_policy_make(north, south)
	defer sd_policy_destroy(pol)
	if pol.overflow {
		return false
	}
	perm: [RANKS]int
	for r in 0 ..< RANKS {
		perm[r] = r
	}
	ev := Policy_Eval {
		pol  = pol,
		perm = perm,
		inv  = perm,
		memo = make(map[Eval_Key]int),
	}
	defer delete(ev.memo)
	lines := candidate_lines()
	for w in initial_worlds(north, south, context.temp_allocator) {
		opt := policy_eval(&ev, pol.root, w.e, w.w, 0, -1)
		got := make([]int, len(names), context.temp_allocator)
		differs := false
		for name, i in names {
			got[i] = -1
			for l in lines {
				if l.name == name {
					got[i] = sd_deal_tricks(l, north, south, w.e, w.w)
				}
			}
			differs = differs || (got[i] >= 0 && got[i] != opt)
		}
		if diff_only && !differs {
			continue
		}
		fmt.sbprintf(b, "W %-8s E %-8s optimum %d", probe_cards(w.w), probe_cards(w.e), opt)
		for name, i in names {
			fmt.sbprintf(b, "  %s %d", name, got[i])
		}
		strings.write_byte(b, '\n')
	}
	return true
}

@(private = "file")
probe_cards :: proc(m: u16) -> string {
	ranks := "23456789TJQKA"
	b := strings.builder_make(context.temp_allocator)
	for r := RANKS - 1; r >= 0; r -= 1 {
		if m & rank_bit(r) != 0 {
			strings.write_byte(&b, ranks[r])
		}
	}
	if m == 0 {
		strings.write_byte(&b, '-')
	}
	return strings.to_string(b)
}
