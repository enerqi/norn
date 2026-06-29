package main

/*
	examples/1major-gf-support — a multi-seat opener+responder generator.

	A multi-seat demo: North opens a 1-major and South holds a game-forcing 13+ with at least three-
	card support. Unlike `strong-1c` (a single seat), this condition reads TWO hands of the deal, so
	the `norn.Predicate` reaches into both `board[.North]` and `board[.South]`.

	The predicate is SELF-CONTAINED (norn primitives only) — a simplified stand-in for the real
	`is_1major_opener` / `has_major_support` predicates, which live in the consumer project that
	depends on norn as a library.

	Build/run from the repo root: odin run examples/1major-gf-support.odin -file -out:target/debug/1major-gf.exe
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

import "../norn"

// The condition (norn primitives only): North opens a 1-major — a 5+ card major with 11-21 hcp —
// and South has a game-forcing 13+ hand with 3+ card support for that major.
north_opens_south_raises :: proc(summary: norn.Deal_Summary) -> bool {
	north := summary[.North]
	south := summary[.South]
	n_hcp := norn.hcp(north)
	if n_hcp < 11 || n_hcp > 21 || norn.hcp(south) < 13 {
		return false
	}
	spade_fit := norn.spade_length(north) >= 5 && norn.spade_length(south) >= 3
	heart_fit := norn.heart_length(north) >= 5 && norn.heart_length(south) >= 3
	return spade_fit || heart_fit
}

main :: proc() {
	// Seed for a reproducible example run.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 1234)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Keep 10 matching deals; cap attempts so an over-restrictive condition can't loop forever.
	accepted, attempts := norn.generate_accepted(&builder, 10, .Line, north_opens_south_raises, 5_000_000)
	fmt.eprintfln("1major-gf-support: accepted %d of %d deals tried", accepted, attempts)

	os.write_string(os.stdout, strings.to_string(builder))
}
