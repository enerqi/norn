package bake_suit_lines

/*
	bake_suit_lines.odin — bakes the suit solver's table (combo/suit_solver_table_data.odin).

	Every class of holdings (see combo/suit_solver_table.odin) with between `min-missing` and `max-missing`
	cards missing is solved on a pool of threads, each searched at the tiers of `combo.SOLVER_TABLE_TIERS` in
	turn until a search finishes (`max-tier` stops earlier), and the classes whose line beats the best fixed line
	are written out, sorted by key. Run it with `just bake-suit-lines`; arguments are `name=value`:

	  out=combo/suit_solver_table_data.odin   where to write the table
	  max-tier=5                              the last tier tried (0 = 3*10^6 only: a quick bake)
	  min-missing=2  max-missing=9            which classes
	  threads=0                               0 = one per logical core, less four (the desktop keeps some)
	  limit=0                                 solve only the first N classes (0 = all), for a trial run
	  redo=0                                  1 = re-solve only the table's entries, each at the tier it
	                                          records (minutes, not hours): after a change to what an entry
	                                          stores, not to the solver. Says how many lines changed.

	RESUMABLE. Every class solved is appended to `<out>.partial` as it finishes; a bake started again with the
	same `out` reads that file and solves only what is missing, and deletes it once the table is written. A full
	bake at every tier is hours, so an interrupted one should not start over. (The partial file is only valid
	for the solver and narration that wrote it - delete it after changing either.)

	Progress goes to stderr; the summary at the end counts each tier's outcomes.
*/

import "core:fmt"
import "core:math/bits"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import si "core:sys/info"
import "core:thread"
import "core:time"

import "../combo"

Job :: struct {
	key:     u32,
	first:   int, // the tiers to try
	last:    int,
	entry:   combo.Solver_Table_Entry,
	outcome: combo.Solver_Table_Outcome,
	cells:   []u16, // the line's joint table (`combo.solver_joint_cells`), for an entry
	done:    bool,
}

jobs: []Job
next_job: int
done: int
max_tier := len(combo.SOLVER_TABLE_TIERS) - 1
partial_mu: sync.Mutex
partial: ^os.File

// One finished class as a line of the partial file: key, outcome, tier, the distribution, label, tooltip,
// joint cells. The words never hold a tab or a newline.
write_partial :: proc(j: ^Job) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%05x\t%d\t%d\t", j.key, int(j.outcome), j.entry.tier)
	for p, k in j.entry.p {
		if k > 0 {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%.9g", p)
	}
	fmt.sbprintf(&b, "\t%s\t%s\t", j.entry.label, j.entry.tip)
	for c, k in j.cells {
		if k > 0 {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%x", c)
	}
	strings.write_byte(&b, '\n')
	sync.mutex_lock(&partial_mu)
	defer sync.mutex_unlock(&partial_mu)
	os.write(partial, b.buf[:])
}

read_partial :: proc(path: string, by_key: map[u32]int) -> (read: int) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 7 {
			continue // a line cut short by the interruption (or an older format: solved again)
		}
		key, _ := strconv.parse_uint(f[0], 16)
		i, known := by_key[u32(key)]
		if !known {
			continue
		}
		j := &jobs[i]
		outcome, _ := strconv.parse_int(f[1])
		tier, _ := strconv.parse_int(f[2])
		j.outcome = combo.Solver_Table_Outcome(outcome)
		j.entry.key, j.entry.tier = u32(key), u8(tier)
		for p, k in strings.split(f[3], " ", context.temp_allocator) {
			v, _ := strconv.parse_f32(p)
			j.entry.p[k] = v
		}
		j.entry.label = strings.clone(f[4])
		j.entry.tip = strings.clone(f[5])
		cells := make([dynamic]u16)
		for c in strings.split(f[6], " ", context.temp_allocator) {
			if v, ok := strconv.parse_uint(c, 16); ok {
				append(&cells, u16(v))
			}
		}
		j.cells = cells[:]
		j.done = true
		read += 1
	}
	return
}

worker :: proc() {
	for {
		i := sync.atomic_add(&next_job, 1)
		if i >= len(jobs) {
			return
		}
		j := &jobs[i]
		if j.done {
			continue
		}
		joint: combo.Suit_Joint_Table
		j.entry, j.outcome, joint = combo.solver_table_solve(j.key, j.first, j.last)
		if j.outcome == .Entry {
			j.cells = combo.solver_joint_cells(joint)
		}
		write_partial(j)
		free_all(context.temp_allocator)
		sync.atomic_add(&done, 1)
	}
}

main :: proc() {
	out := "combo/suit_solver_table_data.odin"
	min_missing, max_missing, threads, limit := 2, 9, 0, 0
	redo := false
	for arg in os.args[1:] {
		name, _, value := strings.partition(arg, "=")
		n, _ := strconv.parse_int(value)
		switch name {
		case "out":
			out = value
		case "max-tier":
			max_tier = clamp(n, 0, len(combo.SOLVER_TABLE_TIERS) - 1)
		case "min-missing":
			min_missing = n
		case "max-missing":
			max_missing = n
		case "threads":
			threads = n
		case "limit":
			limit = n
		case "redo":
			redo = n != 0
		case:
			fmt.eprintfln("unknown argument %q (out, max-tier, min-missing, max-missing, threads, limit, redo)", arg)
			os.exit(2)
		}
	}
	if threads <= 0 {
		threads = 1
		if _, logical, ok := si.cpu_core_count(); ok {
			threads = max(1, logical - 4)
		}
	}

	// Every class, once: the smaller of a key and its mirror.
	list: [dynamic]Job
	for key in u32(0) ..< 1 << 20 {
		if !combo.solver_table_valid(key) || combo.solver_table_mirror(key) < key {
			continue
		}
		north, south := combo.solver_table_holding(key)
		missing := combo.RANKS - int(bits.count_ones(north | south))
		if missing < min_missing || missing > max_missing || north | south == 0 {
			continue
		}
		append(&list, Job{key = key, first = 0, last = max_tier})
	}
	if redo {
		clear(&list)
		for e in combo.SUIT_SOLVER_TABLE {
			append(&list, Job{key = e.key, first = int(e.tier), last = int(e.tier)})
		}
	}
	if limit > 0 && limit < len(list) {
		resize(&list, limit)
	}
	jobs = list[:]
	by_key := make(map[u32]int)
	for j, i in jobs {
		by_key[j.key] = i
	}

	partial_path := strings.concatenate({out, ".partial"})
	resumed := read_partial(partial_path, by_key)
	f, err := os.open(partial_path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err != nil {
		fmt.eprintfln("could not open %s: %v", partial_path, err)
		os.exit(1)
	}
	partial = f
	tiers := combo.SOLVER_TABLE_TIERS
	fmt.eprintfln(
		"%d classes (%d already solved in %s), %d threads, tiers 0..%d (last: budget %d%s)",
		len(jobs),
		resumed,
		partial_path,
		threads,
		max_tier,
		tiers[max_tier].budget,
		", coarse" if tiers[max_tier].coarse else "",
	)

	start := time.now()
	todo := len(jobs) - resumed
	pool := make([]^thread.Thread, threads)
	for &t in pool {
		t = thread.create_and_start(worker)
	}
	for sync.atomic_load(&done) < todo {
		time.sleep(30 * time.Second)
		d := sync.atomic_load(&done)
		el := time.duration_seconds(time.since(start))
		eta := el / f64(max(d, 1)) * f64(todo - d)
		fmt.eprintfln("%d / %d  %.0fs elapsed, about %.0fs left", d, todo, el, eta)
	}
	for t in pool {
		thread.join(t)
	}
	os.close(partial)

	entries: [dynamic]combo.Solver_Table_Entry
	cells_of := make(map[u32][]u16)
	counts: [len(combo.SOLVER_TABLE_TIERS)]int
	no_gain, out_of_budget := 0, 0
	for j in jobs {
		switch j.outcome {
		case .Entry:
			append(&entries, j.entry)
			cells_of[j.key] = j.cells
			counts[j.entry.tier] += 1
		case .No_Gain:
			no_gain += 1
		case .Out_Of_Budget:
			out_of_budget += 1
		}
	}
	slice.sort_by(entries[:], proc(a, b: combo.Solver_Table_Entry) -> bool {return a.key < b.key})

	// A redo did not re-solve the classes without an entry: their counts are the earlier bake's.
	tally := fmt.tprintf("%d found nothing better, %d ran out of every budget.", no_gain, out_of_budget)
	classes := len(jobs)
	if redo {
		tally = "the classes without an entry as the earlier bake found them."
		if old, rerr := os.read_entire_file_from_path(out, context.allocator); rerr == nil {
			text := string(old)
			for line in strings.split_lines_iterator(&text) {
				if strings.has_prefix(line, "// by tier") {
					_, _, rest := strings.partition(line, "; ")
					tally = strings.clone(rest)
				}
				// "// <entries> of <classes> classes (...": the classes the earlier bake covered.
				if _, of, rest := strings.partition(line, " of "); of != "" && strings.has_prefix(line, "// ") {
					if n, ok := strconv.parse_int(strings.split_n(rest, " ", 2, context.temp_allocator)[0]); ok {
						classes = n
					}
				}
			}
		}
		changed := 0
		for j in jobs {
			i, _ := slice.binary_search_by(combo.SUIT_SOLVER_TABLE[:], j.key, proc(e: combo.Solver_Table_Entry, k: u32) -> slice.Ordering {
				return slice.cmp(e.key, k)
			})
			old := combo.SUIT_SOLVER_TABLE[i]
			same := j.outcome == .Entry && j.entry.label == old.label && j.entry.tip == old.tip
			for k in 0 ..= combo.RANKS {
				same = same && abs(j.entry.p[k] - old.p[k]) < 1e-6
			}
			if !same {
				changed += 1
				fmt.eprintfln("  class %05x changed (outcome %v)", j.key, j.outcome)
			}
		}
		fmt.eprintfln("redo: %d of %d lines changed", changed, len(jobs))
	}

	b := strings.builder_make()
	// In every build, the wasm player's too: gzipped in its page the table costs it little (see the size there).
	strings.write_string(&b, "package combo\n\n")
	strings.write_string(
		&b,
		"// Generated by `just bake-suit-lines` (cmd/bake_suit_lines.odin) - do not edit. See suit_solver_table.odin.\n",
	)
	fmt.sbprintf(
		&b,
		"// %d of %d classes (%d to %d cards missing, tiers 0..%d) have a line better than the best fixed one;\n",
		len(entries),
		classes,
		min_missing,
		max_missing,
		max_tier,
	)
	fmt.sbprintf(&b, "// by tier %v; %s\n\n", counts[:max_tier + 1], tally)
	strings.write_string(&b, "@(rodata)\nSUIT_SOLVER_TABLE := [?]Solver_Table_Entry {\n")
	joint := make([dynamic]u16)
	for e in entries {
		fmt.sbprintf(&b, "\t{{0x%05x, %d, {{", e.key, e.tier)
		for p, k in e.p {
			if k > 0 {
				strings.write_string(&b, ", ")
			}
			fmt.sbprintf(&b, "%.9g", p) // nine digits: an f32 read back unchanged
		}
		cells := cells_of[e.key]
		fmt.sbprintf(&b, "}}, %q, %q, %d, %d}},\n", e.label, e.tip, len(joint), len(cells))
		append(&joint, ..cells)
	}
	strings.write_string(&b, "}\n\n// Each entry's line by East's length: see `solver_table_joint`.\n@(rodata)\nSUIT_SOLVER_JOINT := [?]u16 {")
	for c, k in joint {
		strings.write_string(&b, "\n\t" if k % 16 == 0 else " ")
		fmt.sbprintf(&b, "0x%04x,", c)
	}
	strings.write_string(&b, "\n}\n")
	if werr := os.write_entire_file(out, b.buf[:]); werr != nil {
		fmt.eprintfln("could not write %s: %v", out, werr)
		os.exit(1)
	}
	os.remove(partial_path)
	fmt.eprintfln("wrote %s: %d entries of %d classes, in %.0fs", out, len(entries), len(jobs), time.duration_seconds(time.since(start)))
	for c, tier in counts[:max_tier + 1] {
		fmt.eprintfln("  tier %d (budget %d%s): %d entries", tier, tiers[tier].budget, ", coarse" if tiers[tier].coarse else "", c)
	}
	fmt.eprintfln("  nothing better than the fixed line: %d; out of every budget: %d", no_gain, out_of_budget)
}
