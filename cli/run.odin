package cli

/*
	run.odin — the CLI's generation driver.

	The application-policy layer over the reusable `norn` library: pick a seed, drive generation, and
	write the result to stdout or a file. The library stays I/O-free; everything here is the program's
	choice of how to seed and where to send output. A `registry` of `Scenario`s is supplied by the
	caller (the consumer program) — `--scenario` selects one of them and switches generation to reject
	sampling; with no scenario every deal is kept.
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import si "core:sys/info"
import "core:thread"
import "core:time"

import "../norn"

// Carry out the full generation requested by `opts`, choosing scenarios from `registry`. Returns
// ok = false with a message on a bad scenario name or an output error.
run :: proc(registry: []Scenario, opts: Options) -> (ok: bool, message: string) {
	// A scenario name must resolve before we burn any RNG, so validate it up front.
	scenario: Scenario
	if opts.scenario != "" {
		found: bool
		scenario, found = lookup(registry, opts.scenario)
		if !found {
			return false, fmt.tprintf("unknown scenario %q (run --list to see the catalogue)", opts.scenario)
		}
	}

	// Choose the seed. An explicit --seed makes the run reproducible; otherwise we pick a fresh one
	// from the clock and report it on stderr so this exact run can be reproduced later with --seed.
	seed := opts.seed
	if !opts.has_seed {
		seed = fresh_seed()
		fmt.eprintfln("norn: seed=%d (pass --seed %d to reproduce)", seed, seed)
	}

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	// Presize the buffer to the expected output so it rarely has to grow (and copy) mid-run.
	builder := strings.builder_make_len_cap(0, output_size_hint(opts.format, opts.count))
	defer strings.builder_destroy(&builder)

	// Take a pointer to the SmartStack spec (if any) for the generation calls; nil otherwise. The
	// copy lives in `spec` for the duration of this proc.
	ss: ^norn.Smart_Stack
	spec: norn.Smart_Stack
	if got, has := opts.smartstack.?; has {
		spec = got
		ss = &spec
	}

	if opts.scenario == "" {
		norn.render_deals(
			&builder,
			opts.count,
			opts.format,
			randomize_table = opts.randomize_table,
			predeal = opts.predeal,
			smartstack = ss,
		)
	} else {
		// Reject sampling: deal until `count` deals satisfy the scenario. Report the hit rate on
		// stderr so a rare scenario's cost is visible (and a typo'd-rare one is obvious).
		accepted, attempts := norn.generate_accepted(
			&builder,
			opts.count,
			opts.format,
			scenario.predicate,
			randomize_table = opts.randomize_table,
			predeal = opts.predeal,
			smartstack = ss,
		)
		fmt.eprintfln(
			"norn: scenario %q — %d accepted from %d deals (%.3f%%)",
			scenario.name,
			accepted,
			attempts,
			100.0 * f64(accepted) / f64(max(attempts, 1)),
		)
	}

	return write_output(opts.output, strings.to_string(builder))
}

// Batch-export every scenario in `registry` to `<opts.html_dir>/<name>.html`, each an HTML page of
// `opts.count` deals matching that scenario. The Odin equivalent of regen-html-deals.py. Returns
// ok = false with a message on a write error; per-scenario hit rates and any shortfalls are reported
// on stderr.
export_all_html :: proc(registry: []Scenario, opts: Options) -> (ok: bool, message: string) {
	if len(registry) == 0 {
		return false, "no scenarios to export (registry is empty)"
	}

	selected, filter, sel_ok, sel_msg := select_scenarios(registry, opts.scenario)
	defer delete(filter)
	if !sel_ok {
		return false, sel_msg
	}

	// Best-effort: create the output directory if it does not already exist.
	if !os.is_dir(opts.html_dir) {
		if err := os.make_directory(opts.html_dir); err != nil && !os.is_dir(opts.html_dir) {
			return false, fmt.tprintf("could not create output directory %q: %v", opts.html_dir, err)
		}
	}

	// One seed for the whole batch keeps a run reproducible end to end.
	seed := opts.seed
	if !opts.has_seed {
		seed = fresh_seed()
		fmt.eprintfln("norn: seed=%d (pass --seed %d to reproduce)", seed, seed)
	}
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	ss: ^norn.Smart_Stack
	spec: norn.Smart_Stack
	if got, has := opts.smartstack.?; has {
		spec = got
		ss = &spec
	}

	// One builder reused across every scenario: `builder_reset` keeps the backing buffer and just
	// rewinds the length, so we pay the (presized) allocation once instead of churning a fresh buffer
	// per scenario.
	builder := strings.builder_make_len_cap(0, output_size_hint(.Html, opts.count))
	defer strings.builder_destroy(&builder)

	for s in selected {
		strings.builder_reset(&builder)

		// Cap attempts so a very rare scenario can't loop indefinitely; warn if it under-fills.
		accepted, attempts := norn.generate_accepted(
			&builder,
			opts.count,
			.Html,
			s.predicate,
			HTML_EXPORT_MAX_ATTEMPTS,
			opts.randomize_table,
			opts.predeal,
			ss,
		)
		if accepted < opts.count {
			fmt.eprintfln(
				"norn: scenario %q under-filled — %d of %d after %d deals (rare condition)",
				s.name,
				accepted,
				opts.count,
				attempts,
			)
		}

		path := fmt.tprintf("%s/%s.html", opts.html_dir, s.name)
		if write_ok, write_msg := write_output(path, strings.to_string(builder)); !write_ok {
			return false, write_msg
		}
	}

	fmt.eprintfln("norn: exported %d scenarios to %q", len(selected), opts.html_dir)
	return true, ""
}

// Resolve which scenarios a batch command should act on. `selector` is the raw --scenario value: an
// empty string means the whole `registry`; otherwise it is a comma-separated list of names, each of
// which must resolve. On success `selected` is the slice to use; when a subset was named, `filter`
// owns its backing storage and the caller must `delete(filter)` (it is the empty/nil dynamic array
// when the whole registry is selected, which `delete` accepts harmlessly).
select_scenarios :: proc(
	registry: []Scenario,
	selector: string,
) -> (
	selected: []Scenario,
	filter: [dynamic]Scenario,
	ok: bool,
	message: string,
) {
	if selector == "" {
		return registry, nil, true, ""
	}
	names := strings.split(selector, ",")
	defer delete(names)
	for raw in names {
		name := strings.trim_space(raw)
		if name == "" {
			continue
		}
		s, found := lookup(registry, name)
		if !found {
			delete(filter)
			return nil, nil, false, fmt.tprintf("unknown scenario %q (run --list to see the catalogue)", name)
		}
		append(&filter, s)
	}
	if len(filter) == 0 {
		delete(filter)
		return nil, nil, false, "--scenario selected no scenarios"
	}
	return filter[:], filter, true, ""
}

// One scenario's measurement job, handed to a worker thread: count how many of `trials` deals
// `predicate` keeps, using an RNG seeded by `seed`, and store the answer in `result`. Each task owns
// a distinct `result` slot, so the workers never write the same memory.
Freq_Task :: struct {
	trials:     int,
	seed:       u64,
	predicate:  norn.Predicate,
	predeal:    Maybe(norn.Predeal),
	// Shared, read-only across workers: the sampler only reads the spec (randomness comes from each
	// task's own seeded RNG), so one pointer is safe to hand to every thread. nil if no --smartstack.
	smartstack: ^norn.Smart_Stack,
	result:     ^int,
}

// Thread-pool body: run one scenario's measurement. Self-contained — `count_accepted_seeded`
// installs its own RNG, so nothing here touches shared mutable state.
freq_worker :: proc(t: thread.Task) {
	job := cast(^Freq_Task)t.data
	job.result^ = norn.count_accepted_seeded(job.trials, job.predicate, job.seed, job.predeal, job.smartstack)
}

// Derive a per-scenario seed from the run's base seed and the scenario's index, so each scenario
// gets an independent RNG stream that is the SAME no matter which thread runs it or how many threads
// are used. (Fibonacci-hashing the index by the golden-ratio constant scrambles adjacent indices
// into far-apart seeds; u64 wrapping is intended.)
scenario_seed :: proc(base: u64, index: int) -> u64 {
	return base + (u64(index) + 1) * 0x9E37_79B9_7F4A_7C15
}

// Measure each selected scenario's acceptance rate over `opts.trials` random deals and print one
// line per scenario to stdout: name, hits, trials and percentage. No deals are rendered.
//
// The scenarios are independent, so the work is split across a thread pool — up to one thread per
// physical core, never more than there are scenarios. Each scenario is seeded independently of the
// partition (see `scenario_seed`), so the output is identical whether it runs on 1 thread or many,
// and is reproducible from --seed. Returns ok = false with a message on a bad scenario name or empty
// registry.
measure_frequencies :: proc(registry: []Scenario, opts: Options) -> (ok: bool, message: string) {
	if len(registry) == 0 {
		return false, "no scenarios to measure (registry is empty)"
	}

	selected, filter, sel_ok, sel_msg := select_scenarios(registry, opts.scenario)
	defer delete(filter)
	if !sel_ok {
		return false, sel_msg
	}

	// One base seed keeps the whole run reproducible; the per-scenario seeds derive from it.
	seed := opts.seed
	if !opts.has_seed {
		seed = fresh_seed()
		fmt.eprintfln("norn: seed=%d (pass --seed %d to reproduce)", seed, seed)
	}

	// One thread per physical core, capped at the number of scenarios (no point spawning idle
	// workers). Fall back to a single thread if the core count can't be determined.
	thread_count := 1
	if physical, _, cores_ok := si.cpu_core_count(); cores_ok {
		thread_count = physical
	}
	thread_count = clamp(thread_count, 1, len(selected))

	// Shared SmartStack spec (read-only) handed to every worker; lives until the pool finishes.
	ss: ^norn.Smart_Stack
	spec: norn.Smart_Stack
	if got, has := opts.smartstack.?; has {
		spec = got
		ss = &spec
	}

	results := make([]int, len(selected))
	defer delete(results)
	jobs := make([]Freq_Task, len(selected))
	defer delete(jobs)
	for s, i in selected {
		jobs[i] = Freq_Task{opts.trials, scenario_seed(seed, i), s.predicate, opts.predeal, ss, &results[i]}
	}

	if thread_count <= 1 {
		// Single core (or a lone scenario): skip the pool machinery and run inline.
		for &job in jobs {
			freq_worker(thread.Task{data = &job})
		}
	} else {
		fmt.eprintfln("norn: measuring %d scenarios on %d threads", len(selected), thread_count)
		pool: thread.Pool
		thread.pool_init(&pool, context.allocator, thread_count)
		defer thread.pool_destroy(&pool)
		for &job, i in jobs {
			thread.pool_add_task(&pool, context.allocator, freq_worker, &job, i)
		}
		thread.pool_start(&pool)
		thread.pool_finish(&pool) // processes remaining tasks on this thread too, then joins
	}

	// Align the name column for readable output.
	width := 0
	for s in selected {
		if len(s.name) > width {
			width = len(s.name)
		}
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for s, i in selected {
		fmt.sbprintfln(
			&builder,
			"%-*s  %d / %d  (%.4f%%)",
			width,
			s.name,
			results[i],
			opts.trials,
			100.0 * f64(results[i]) / f64(opts.trials),
		)
	}

	return write_output(opts.output, strings.to_string(builder))
}

// Attempt budget per scenario in `export_all_html`, so a rare condition under-fills rather than
// hanging the whole batch. Generous because norn deals far faster than the interpreted engine.
HTML_EXPORT_MAX_ATTEMPTS :: 20_000_000

// Rough upper estimate of the rendered byte size of `count` deals in `format`, used to presize the
// output builder so it rarely has to grow (and copy) mid-run. Over-estimates are harmless (a little
// reserved memory that is freed with the builder); the per-deal figures are padded above the worst
// real case, and HTML adds the one-off page header/footer plus an iframe wrapper per deal.
@(private = "file")
output_size_hint :: proc(format: norn.Output_Format, count: int) -> int {
	per_deal := 80 // Line / Pbn / Numeric all sit well under this
	overhead := 0
	#partial switch format {
	case .Pretty:
		per_deal = 160
	case .Handviewer:
		per_deal = 140
	case .Html:
		per_deal = 600 // iframe wrapper + handviewer URL
		overhead = 512 // page header + footer, emitted once around the run
	}
	return per_deal * max(count, 0) + overhead + 64
}

// Write `text` to `path`, or to stdout when `path` is "-".
write_output :: proc(path: string, text: string) -> (ok: bool, message: string) {
	if path == "-" {
		os.write_string(os.stdout, text)
		return true, ""
	}
	if err := os.write_entire_file(path, text); err != nil {
		return false, fmt.tprintf("could not write to %q: %v", path, err)
	}
	return true, ""
}

// A fresh, non-reproducible seed derived from the current time. Good enough to make each unseeded
// run differ; for reproducibility the caller passes --seed instead.
fresh_seed :: proc() -> u64 {
	return u64(time.now()._nsec)
}
