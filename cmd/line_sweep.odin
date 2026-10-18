package line_sweep

/*
	line_sweep.odin — the fixed lines held to the exact single-dummy optimum (`just combo-line-sweep`).

	Deals random holdings, solves each one EXACTLY (`combo.sd_optimal_distribution`; holdings the search cannot
	finish in its default budget are skipped) and compares the best fixed line with the optimum. It prints how
	far the fixed lines fall short overall and the holdings where they fall furthest, worst first: the work list
	for the line generator. A broken line shows up here as a gap that should not be there - the finesse lines'
	bugs of 2026-10-17 were most of the list's top before they were found.

	Arguments are `name=value`:
	  count=400     holdings dealt
	  seed=12345    the random seed (the same seed deals the same holdings)
	  min=7 max=10  cards North-South hold (3 to 6 missing: what the search finishes)
	  top=25        how many of the worst gaps to list
	  pin=0         1 = also print every holding as a `Pinned` row for combo's
	                `test_the_fixed_lines_hold_their_ground` (pick from them; do not paste them all)
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../combo"

Row :: struct {
	north, south: u16,
	opt, fixed:   f64,
	line:         string,
}

main :: proc() {
	count, seed, lo, hi, top, pin := 400, 12345, 7, 10, 25, 0
	for arg in os.args[1:] {
		name, _, value := strings.partition(arg, "=")
		n, ok := strconv.parse_int(value)
		if !ok {
			fmt.eprintfln("line_sweep: %q is not name=number", arg)
			os.exit(2)
		}
		switch name {
		case "count":
			count = n
		case "seed":
			seed = n
		case "min":
			lo = n
		case "max":
			hi = n
		case "top":
			top = n
		case "pin":
			pin = n
		case:
			fmt.eprintfln("line_sweep: unknown argument %q", name)
			os.exit(2)
		}
	}

	rand.reset(u64(seed))
	rows := make([dynamic]Row)
	defer delete(rows)
	for i in 0 ..< count {
		north, south: u16
		perm := rand.perm(13, context.temp_allocator)
		for k in 0 ..< lo + rand.int_max(hi - lo + 1) {
			if rand.int_max(2) == 0 {
				north |= u16(1) << uint(perm[k])
			} else {
				south |= u16(1) << uint(perm[k])
			}
		}
		if north == 0 || south == 0 {
			continue
		}
		opt, exact := combo.sd_optimal_expected_tricks(north, south)
		free_all(context.temp_allocator)
		if !exact {
			continue
		}
		best := combo.best_line_by_mean(north, south)
		append(&rows, Row{north, south, opt, combo.expected_tricks(best.dist.p), best.name})
		if (i + 1) % 50 == 0 {
			fmt.eprintf("\r%d of %d dealt, %d solved exactly", i + 1, count, len(rows))
		}
	}
	fmt.eprintln()

	if pin != 0 {
		for r in rows {
			fmt.printfln("\t\t{{0x%04x, 0x%04x, %.6f, %.6f}}, // %s opposite %s", r.north, r.south, r.fixed, r.opt, holding(r.north), holding(r.south))
		}
		fmt.println()
	}

	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.opt - a.fixed > b.opt - b.fixed})
	short, total := 0, 0.0
	for r in rows {
		total += r.opt - r.fixed
		if r.opt - r.fixed > 0.02 {
			short += 1
		}
	}
	fmt.printfln(
		"%d holdings solved exactly: the best fixed line is %.4f of a trick short of the optimum on average, more than 0.02 short on %d",
		len(rows),
		total / f64(max(len(rows), 1)),
		short,
	)
	for r in rows[:min(top, len(rows))] {
		fmt.printfln(
			"  %-10s opposite %-10s optimum %.3f  fixed %.3f (%s)  short %.3f",
			holding(r.north),
			holding(r.south),
			r.opt,
			r.fixed,
			r.line,
			r.opt - r.fixed,
		)
	}
}

holding :: proc(m: u16) -> string {
	ranks := "23456789TJQKA"
	b := strings.builder_make(context.temp_allocator)
	for r := 12; r >= 0; r -= 1 {
		if m & (u16(1) << uint(r)) != 0 {
			strings.write_byte(&b, ranks[r])
		}
	}
	return strings.to_string(b)
}
