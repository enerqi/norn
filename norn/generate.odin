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

// A second-stage condition over the RAW dealt cards, run only on boards the cheap `Predicate`
// already kept (see `generate_accepted`). It reads the full `Deal` — the actual 52 cards, not the
// bitmask summary — so it can decide things a summary cannot express (double-dummy tricks, par
// score). It is I/O-free and knows nothing about any solver: a consumer supplies one that adapts
// the `Deal` to whatever engine it wants. nil means "no second stage". Because it runs after the
// summary predicate, an expensive analysis only touches the (already selective) survivors.
Deal_Filter :: proc(board: Deal) -> bool

// A hook to append extra text to each RENDERED board, right after its normal rendering (see
// `generate_accepted`). Like `Deal_Filter` it reads the raw `Deal` and is engine-agnostic; a
// consumer uses it to annotate a deal with, e.g., its double-dummy result. nil means "render
// nothing extra".
//
// It receives the active `Output_Format` because annotation is inherently format-specific: an HTML
// caption would corrupt a PBN tag or a machine-parsed `Line`. The annotator must emit only what is
// valid for `format` (and emit nothing for formats it can't safely extend), so it fires for every
// format but stays the annotator's responsibility to keep each one well-formed.
Deal_Annotator :: proc(builder: ^strings.Builder, board: Deal, format: Output_Format)

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
	annotate: Deal_Annotator = nil,
	page_title := "",
) {
	generate_accepted(
		builder,
		count,
		format,
		accept_all,
		randomize_table = randomize_table,
		predeal = predeal,
		smartstack = smartstack,
		annotate = annotate,
		page_title = page_title,
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
	deal_filter: Deal_Filter = nil,
	annotate: Deal_Annotator = nil,
	page_title := "",
) -> (
	accepted: int,
	attempts: int,
) {
	pd, has_predeal := predeal.?
	// Page-oriented formats (Html) wrap the run in a header/footer; per-deal formats emit nothing
	// here. The prologue/epilogue bracket the whole accepted set, not each deal.
	render_page_prologue(builder, format, page_title)
	for accepted < count {
		if max_attempts > 0 && attempts >= max_attempts {
			break
		}
		board := next_board(pd, has_predeal, smartstack)
		attempts += 1
		// Build the index once per board; the predicate (and all its evaluator calls) read it. Only
		// when the cheap summary predicate passes do we pay for the optional raw-deal filter (e.g. a
		// double-dummy solve), so the expensive stage runs on the survivors, not every board.
		if accept(summarize_deal(board)) && (deal_filter == nil || deal_filter(board)) {
			render_deal(builder, board, format, randomize_table)
			if annotate != nil {
				annotate(builder, board, format)
			}
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
//
// `deal_filter` is the same optional second stage `generate_accepted` applies: when non-nil a board
// counts only if it passes BOTH the cheap summary predicate and the raw-deal filter, so the measured
// rate matches what generation would actually keep (e.g. after a double-dummy filter). nil measures
// the predicate alone. As in generation, the filter is evaluated only on boards the predicate keeps.
count_accepted :: proc(
	trials: int,
	accept: Predicate,
	predeal: Maybe(Predeal) = nil,
	smartstack: ^Smart_Stack = nil,
	deal_filter: Deal_Filter = nil,
) -> (
	accepted: int,
) {
	pd, has_predeal := predeal.?
	for _ in 0 ..< trials {
		board := next_board(pd, has_predeal, smartstack)
		if accept(summarize_deal(board)) && (deal_filter == nil || deal_filter(board)) {
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
	deal_filter: Deal_Filter = nil,
) -> (
	accepted: int,
) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, seed)
	return count_accepted(trials, accept, predeal, smartstack, deal_filter)
}
