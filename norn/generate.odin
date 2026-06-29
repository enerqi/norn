package norn

/*
	generate.odin — the reusable generation core.

	This is the I/O-free heart of the library: it deals boards and renders the ones a condition
	keeps, into a caller-supplied builder. It makes no process-lifecycle assumptions (no os.exit, no
	stdout, no global one-shot state), so a program can call it many times — e.g. once per condition
	when several generators are compiled into a single binary. Seeding the RNG and writing the result
	somewhere are the caller's job (see the CLI's run.odin).
*/

import "core:math/rand"
import "core:strings"

// A condition on a generated board: returns true to keep it. It reads a `Deal_Summary` — the
// per-seat bitmask index every evaluator now runs on (see summary.odin) — built once per board by
// the generation core, so a predicate firing dozens of evaluator queries pays no per-query rescan.
// A multi-seat condition reads several seats (e.g. North as opener and South as responder). This is
// the Odin equivalent of a `deal` Tcl script's `main { ... accept/reject ... }` body.
Predicate :: proc(summary: Deal_Summary) -> bool

// The trivial predicate that keeps every board (the default when no condition is given).
accept_all :: proc(summary: Deal_Summary) -> bool {
	return true
}

// Append `count` deals to `builder`, one per line, using `context.random_generator`. Each board is
// rendered with `format` and followed by a newline, so consumers can read the output line by line.
// `randomize_table` is forwarded to the renderer (see `render_deal`).
render_deals :: proc(
	builder: ^strings.Builder,
	count: int,
	format: Output_Format,
	randomize_table := false,
	predeal: Maybe(Predeal) = nil,
	smartstack: ^Smart_Stack = nil,
) {
	generate_accepted(
		builder,
		count,
		format,
		accept_all,
		randomize_table = randomize_table,
		predeal = predeal,
		smartstack = smartstack,
	)
}

// Source the next board: from the SmartStack if one is given (biased rare-hand generation), else
// from the predeal if one is given (fixed cards), else a plain uniform deal. SmartStack and predeal
// are mutually exclusive — SmartStack already lays out a whole seat — so SmartStack wins if both are
// (mistakenly) supplied.
@(private)
next_board :: proc(pd: Predeal, has_predeal: bool, smartstack: ^Smart_Stack) -> Deal {
	if smartstack != nil {
		return deal_board_smartstack(smartstack)
	}
	if has_predeal {
		return deal_board_predealt(pd)
	}
	return deal_board()
}

// Reject sampling: keep dealing boards and render the ones `accept` keeps, until `count` have been
// accepted or `max_attempts` boards have been tried. `max_attempts == 0` means no limit — deal
// forever until `count` are found (matching `deal`'s behaviour; the caller is responsible for not
// passing an impossible condition).
//
// Returns how many boards were accepted and how many were tried. `attempts > accepted` indicates
// how selective the condition was; hitting `max_attempts` with `accepted < count` means the
// condition was rarer than the budget allowed.
generate_accepted :: proc(
	builder: ^strings.Builder,
	count: int,
	format: Output_Format,
	accept: Predicate,
	max_attempts := 0,
	randomize_table := false,
	predeal: Maybe(Predeal) = nil,
	smartstack: ^Smart_Stack = nil,
) -> (
	accepted: int,
	attempts: int,
) {
	pd, has_predeal := predeal.?
	// Page-oriented formats (Html) wrap the run in a header/footer; per-deal formats emit nothing
	// here. The prologue/epilogue bracket the whole accepted set, not each deal.
	render_page_prologue(builder, format)
	for accepted < count {
		if max_attempts > 0 && attempts >= max_attempts {
			break
		}
		board := next_board(pd, has_predeal, smartstack)
		attempts += 1
		// Build the index once per board; the predicate (and all its evaluator calls) read it.
		if accept(summarize_deal(board)) {
			render_deal(builder, board, format, randomize_table)
			strings.write_byte(builder, '\n')
			accepted += 1
		}
	}
	render_page_epilogue(builder, format)
	return
}

// Measure how often `accept` keeps a board, without rendering anything: deal `trials` boards and
// return how many were accepted. This is the frequency-estimation counterpart to
// `generate_accepted` — same dealing, no I/O and no builder, so a caller can profile a condition's
// rarity over a large sample cheaply. The acceptance rate is `accepted / trials`.
count_accepted :: proc(
	trials: int,
	accept: Predicate,
	predeal: Maybe(Predeal) = nil,
	smartstack: ^Smart_Stack = nil,
) -> (
	accepted: int,
) {
	pd, has_predeal := predeal.?
	for _ in 0 ..< trials {
		board := next_board(pd, has_predeal, smartstack)
		if accept(summarize_deal(board)) {
			accepted += 1
		}
	}
	return
}

// As `count_accepted`, but self-contained: it installs its OWN seeded RNG into the local `context`
// rather than reading whatever `context.random_generator` happens to be. This is what makes the
// measurement safe to run on a worker thread — each call owns an independent xoshiro stream keyed by
// `seed`, with no shared mutable state — and reproducible: the same `seed` always yields the same
// count, regardless of which thread runs it or how many run concurrently.
count_accepted_seeded :: proc(
	trials: int,
	accept: Predicate,
	seed: u64,
	predeal: Maybe(Predeal) = nil,
	smartstack: ^Smart_Stack = nil,
) -> (
	accepted: int,
) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, seed)
	return count_accepted(trials, accept, predeal, smartstack)
}
