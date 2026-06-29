package main

/*
	cmd/bench — hand-evaluation cost of the bitmask index.

	Now that every evaluator runs on a `Hand_Summary` (see norn/summary.odin), this measures the two
	things that remain: how much the per-deal index build costs, and how cheap evaluation is once the
	index exists — both against the deal/shuffle cost they sit next to. Follows the `core:time`
	Benchmark_Options style.

	A representative multi-seat predicate ("does any seat hold a limited 1-major opener?") runs over a
	fixed pool of pre-generated random deals so predicate cost is isolated from RNG/shuffle. Three
	benches:

	  deal         — deal_board() only (shuffle baseline, for the predicate-vs-deal ratio)
	  summary      — predicate with the index built fresh inside the loop (what generation does today)
	  summary_pre  — predicate over a pre-built index (analyse only — the ceiling if the build were
	                 hoisted/cached)

	Run: just bench   (release, optimised). Override iterations with -define:COUNT_ITERATIONS=n.
*/

import "core:fmt"
import "core:math/rand"
import "core:time"

import "../norn"

COUNT_ITERATIONS :: #config(COUNT_ITERATIONS, 5_000_000)
POOL :: 1 << 16 // 65536 deals, power of two so indexing is a mask
POOL_MASK :: POOL - 1

// Pre-generated deals and their pre-built indexes (filled in main, read by the benches).
deals: [POOL]norn.Deal
summaries: [POOL]norn.Deal_Summary

// Sink to stop the optimiser deleting the work under test.
sink: int

// --- The representative predicate, over the bitmask index. ---

// Does this hand open a limited (11-15) 1-major? A trimmed `is_1major_opener` that still exercises
// the hot mix: hcp, four suit lengths, a shape test, controls, pattern, and honour counts.
qualifies :: proc(s: norn.Hand_Summary) -> bool {
	p := norn.hcp(s)
	if p < 11 || p > 15 {
		return false
	}
	ss := norn.spade_length(s)
	hs := norn.heart_length(s)
	ds := norn.diamond_length(s)
	cs := norn.club_length(s)
	if ss < 5 && hs < 5 {
		return false
	}
	if norn.is_nt5cM_shape(s) && p >= 13 {
		return false
	}
	if cs > hs && cs > ss {
		return false
	}
	if ds > hs && ds > ss {
		return false
	}
	// Gambling-3NT-ish exclusion: a long solid major.
	if norn.controls(s) <= 5 && norn.pattern(s) != ([norn.SUIT_COUNT]int{7, 2, 2, 2}) {
		if (norn.top5q(s, .Spades) >= 6 && ss >= 7 && norn.top_count(s, .Spades, 2) == 2) ||
		   (norn.top5q(s, .Hearts) >= 6 && hs >= 7 && norn.top_count(s, .Hearts, 2) == 2) {
			return false
		}
	}
	return true
}

// Multi-seat: accept the deal if ANY seat qualifies (forces up to four hand evaluations).
any_seat_summary_pre :: proc(ds: norn.Deal_Summary) -> bool {
	for seat in norn.Seat {
		if qualifies(ds[seat]) {
			return true
		}
	}
	return false
}

any_seat_summary :: proc(board: norn.Deal) -> bool {
	for seat in norn.Seat {
		if qualifies(norn.summarize(board[seat])) {
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

	// Correctness gate: build-fresh and pre-built must agree on every pooled deal.
	mismatches := 0
	accepts := 0
	for i in 0 ..< POOL {
		a := any_seat_summary(deals[i])
		b := any_seat_summary_pre(summaries[i])
		if a != b {
			mismatches += 1
		}
		if a {
			accepts += 1
		}
	}
	if mismatches > 0 {
		fmt.printfln("FAIL: build-fresh and pre-built disagree on %d/%d deals", mismatches, POOL)
		return
	}
	fmt.printfln(
		"index agrees fresh-vs-prebuilt on all %d pooled deals; accept rate %.1f%% (%d iterations/bench)\n",
		POOL,
		100.0 * f64(accepts) / f64(POOL),
		COUNT_ITERATIONS,
	)

	opt_deal := &time.Benchmark_Options{bench = bench_deal}
	opt_summary := &time.Benchmark_Options{bench = bench_summary}
	opt_summary_pre := &time.Benchmark_Options{bench = bench_summary_pre}

	time.benchmark(opt_deal)
	time.benchmark(opt_summary)
	time.benchmark(opt_summary_pre)

	report("deal", opt_deal)
	report("summary", opt_summary)
	report("summary_pre", opt_summary_pre)

	sum_ns := f64(time.duration_nanoseconds(opt_summary.duration)) / f64(COUNT_ITERATIONS)
	pre_ns := f64(time.duration_nanoseconds(opt_summary_pre.duration)) / f64(COUNT_ITERATIONS)
	fmt.printfln("\nindex build cost (build+analyse vs analyse-only): %.2fx", sum_ns / pre_ns)

	// Keep the sink live so none of the loops are optimised away.
	fmt.printfln("(sink=%d)", sink)
}
