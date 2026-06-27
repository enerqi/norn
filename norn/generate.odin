package norn

/*
	generate.odin — the reusable generation core.

	This is the I/O-free heart of the library: it deals boards and renders the ones a condition
	keeps, into a caller-supplied builder. It makes no process-lifecycle assumptions (no os.exit, no
	stdout, no global one-shot state), so a program can call it many times — e.g. once per condition
	when several generators are compiled into a single binary. Seeding the RNG and writing the result
	somewhere are the caller's job (see the CLI's run.odin).
*/

import "core:strings"

// A condition on a generated board: returns true to keep it. A multi-seat condition reads several
// seats of the `Deal` (e.g. North as opener and South as responder). This is the Odin equivalent of
// a `deal` Tcl script's `main { ... accept/reject ... }` body.
Predicate :: proc(board: Deal) -> bool

// The trivial predicate that keeps every board (the default when no condition is given).
accept_all :: proc(board: Deal) -> bool {
	return true
}

// Append `count` deals to `builder`, one per line, using `context.random_generator`. Each board is
// rendered with `format` and followed by a newline, so consumers can read the output line by line.
render_deals :: proc(builder: ^strings.Builder, count: int, format: Output_Format) {
	generate_accepted(builder, count, format, accept_all)
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
) -> (
	accepted: int,
	attempts: int,
) {
	for accepted < count {
		if max_attempts > 0 && attempts >= max_attempts {
			break
		}
		board := deal_board()
		attempts += 1
		if accept(board) {
			render_deal(builder, board, format)
			strings.write_byte(builder, '\n')
			accepted += 1
		}
	}
	return
}
