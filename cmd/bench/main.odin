package main

/*
	cmd/bench — scan vs bitmask-index hand evaluation.

	Measures whether replacing the 13-card scan primitives with a precomputed `HandSummary` bitmask
	(see norn/summary.odin) actually pays off, and how predicate cost compares to the deal/shuffle
	cost it sits next to. Follows the `core:time` Benchmark_Options style.

	A representative multi-seat predicate ("does any seat hold a limited 1-major opener?") is written
	twice — once against the scan primitives, once against the index — and benchmarked over a fixed
	pool of pre-generated random deals so the predicate cost is isolated from RNG/shuffle. Four
	benches:

	  deal         — deal_board() only (shuffle baseline, for the predicate-vs-deal ratio)
	  scan         — predicate via the scan primitives
	  summary      — predicate via the index, built fresh inside the loop (realistic: build + analyse)
	  summary_pre  — predicate via a pre-built index (analyse only — the ceiling)

	Run: just bench   (release, optimised). Override iterations with -define:COUNT_ITERATIONS=n.
*/

import "core:fmt"
import "core:math/rand"
import "core:time"

import "../../norn"

COUNT_ITERATIONS :: #config(COUNT_ITERATIONS, 5_000_000)
POOL :: 1 << 16 // 65536 deals, power of two so indexing is a mask
POOL_MASK :: POOL - 1

// Pre-generated deals and their pre-built indexes (filled in main, read by the benches).
deals: [POOL]norn.Deal
summaries: [POOL]norn.Deal_Summary

// Sink to stop the optimiser deleting the work under test.
sink: int

// --- The representative predicate, written against each representation. ---

// Does this hand open a limited (11-15) 1-major? A trimmed `is_1major_opener` that still exercises
// the hot mix: hcp, four suit lengths, a shape test, controls, pattern, and honour counts.
qualifies_scan :: proc(h: norn.Hand) -> bool {
	p := norn.hcp(h)
	if p < 11 || p > 15 {
		return false
	}
	ss := norn.spade_length(h)
	hs := norn.heart_length(h)
	ds := norn.diamond_length(h)
	cs := norn.club_length(h)
	if ss < 5 && hs < 5 {
		return false
	}
	if norn.is_nt5cM_shape(h) && p >= 13 {
		return false
	}
	if cs > hs && cs > ss {
		return false
	}
	if ds > hs && ds > ss {
		return false
	}
	// Gambling-3NT-ish exclusion: a long solid major.
	if norn.controls(h) <= 5 && norn.pattern(h) != ([norn.SUIT_COUNT]int{7, 2, 2, 2}) {
		if (norn.top5q(h, .Spades) >= 6 && ss >= 7 && norn.top_count(h, .Spades, 2) == 2) ||
		   (norn.top5q(h, .Hearts) >= 6 && hs >= 7 && norn.top_count(h, .Hearts, 2) == 2) {
			return false
		}
	}
	return true
}

// The same predicate, over the bitmask index.
qualifies_summary :: proc(s: norn.HandSummary) -> bool {
	p := norn.s_hcp(s)
	if p < 11 || p > 15 {
		return false
	}
	ss := norn.s_spade_length(s)
	hs := norn.s_heart_length(s)
	ds := norn.s_diamond_length(s)
	cs := norn.s_club_length(s)
	if ss < 5 && hs < 5 {
		return false
	}
	if norn.s_is_nt5cM_shape(s) && p >= 13 {
		return false
	}
	if cs > hs && cs > ss {
		return false
	}
	if ds > hs && ds > ss {
		return false
	}
	if norn.s_controls(s) <= 5 && norn.s_pattern(s) != ([norn.SUIT_COUNT]int{7, 2, 2, 2}) {
		if (norn.s_top5q(s, .Spades) >= 6 && ss >= 7 && norn.s_top_count(s, .Spades, 2) == 2) ||
		   (norn.s_top5q(s, .Hearts) >= 6 && hs >= 7 && norn.s_top_count(s, .Hearts, 2) == 2) {
			return false
		}
	}
	return true
}

// Multi-seat: accept the deal if ANY seat qualifies (forces up to four hand evaluations).
any_seat_scan :: proc(board: norn.Deal) -> bool {
	for seat in norn.Seat {
		if qualifies_scan(board[seat]) {
			return true
		}
	}
	return false
}

any_seat_summary_pre :: proc(ds: norn.Deal_Summary) -> bool {
	for seat in norn.Seat {
		if qualifies_summary(ds[seat]) {
			return true
		}
	}
	return false
}

any_seat_summary :: proc(board: norn.Deal) -> bool {
	for seat in norn.Seat {
		if qualifies_summary(norn.summarize(board[seat])) {
			return true
		}
	}
	return false
}

// --- Benches. ---

bench_deal :: proc(options: ^time.Benchmark_Options, allocator := context.allocator) -> time.Benchmark_Error {
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 99)
	local := 0
	for _ in 0 ..< COUNT_ITERATIONS {
		board := norn.deal_board()
		local += int(board[.North][0]) // touch the result
	}
	sink += local
	options.count = COUNT_ITERATIONS
	return .Okay
}

bench_scan :: proc(options: ^time.Benchmark_Options, allocator := context.allocator) -> time.Benchmark_Error {
	local := 0
	for i in 0 ..< COUNT_ITERATIONS {
		if any_seat_scan(deals[i & POOL_MASK]) {
			local += 1
		}
	}
	sink += local
	options.count = COUNT_ITERATIONS
	return .Okay
}

bench_summary :: proc(options: ^time.Benchmark_Options, allocator := context.allocator) -> time.Benchmark_Error {
	local := 0
	for i in 0 ..< COUNT_ITERATIONS {
		if any_seat_summary(deals[i & POOL_MASK]) {
			local += 1
		}
	}
	sink += local
	options.count = COUNT_ITERATIONS
	return .Okay
}

bench_summary_pre :: proc(options: ^time.Benchmark_Options, allocator := context.allocator) -> time.Benchmark_Error {
	local := 0
	for i in 0 ..< COUNT_ITERATIONS {
		if any_seat_summary_pre(summaries[i & POOL_MASK]) {
			local += 1
		}
	}
	sink += local
	options.count = COUNT_ITERATIONS
	return .Okay
}

report :: proc(name: string, options: ^time.Benchmark_Options) {
	per_call := f64(time.duration_nanoseconds(options.duration)) / f64(COUNT_ITERATIONS)
	fmt.printfln("%-13s %8.2f ns/op   %.3e ops/sec", name, per_call, options.rounds_per_second)
}

main :: proc() {
	// Build the fixed pool of deals and their indexes once.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 1234)
	for i in 0 ..< POOL {
		deals[i] = norn.deal_board()
		summaries[i] = norn.summarize_deal(deals[i])
	}

	// Correctness gate: the two representations must agree on every pooled deal.
	mismatches := 0
	accepts := 0
	for i in 0 ..< POOL {
		a := any_seat_scan(deals[i])
		b := any_seat_summary_pre(summaries[i])
		if a != b {
			mismatches += 1
		}
		if a {
			accepts += 1
		}
	}
	if mismatches > 0 {
		fmt.printfln("FAIL: scan and summary disagree on %d/%d deals", mismatches, POOL)
		return
	}
	fmt.printfln(
		"scan == summary on all %d pooled deals; accept rate %.1f%% (%d iterations/bench)\n",
		POOL,
		100.0 * f64(accepts) / f64(POOL),
		COUNT_ITERATIONS,
	)

	opt_deal := &time.Benchmark_Options{bench = bench_deal}
	opt_scan := &time.Benchmark_Options{bench = bench_scan}
	opt_summary := &time.Benchmark_Options{bench = bench_summary}
	opt_summary_pre := &time.Benchmark_Options{bench = bench_summary_pre}

	time.benchmark(opt_deal)
	time.benchmark(opt_scan)
	time.benchmark(opt_summary)
	time.benchmark(opt_summary_pre)

	report("deal", opt_deal)
	report("scan", opt_scan)
	report("summary", opt_summary)
	report("summary_pre", opt_summary_pre)

	scan_ns := f64(time.duration_nanoseconds(opt_scan.duration)) / f64(COUNT_ITERATIONS)
	sum_ns := f64(time.duration_nanoseconds(opt_summary.duration)) / f64(COUNT_ITERATIONS)
	pre_ns := f64(time.duration_nanoseconds(opt_summary_pre.duration)) / f64(COUNT_ITERATIONS)
	fmt.printfln("\npredicate speedup  build+analyse: %.2fx   analyse-only: %.2fx", scan_ns / sum_ns, scan_ns / pre_ns)

	// Keep the sink live so none of the loops are optimised away.
	fmt.printfln("(sink=%d)", sink)
}
