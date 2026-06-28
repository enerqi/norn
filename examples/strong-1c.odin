package main

/*
	examples/strong-1c — a single-condition generator program.

	This is the shape every deal simulation takes: a tiny `package main` that imports the `norn`
	engine, defines a `norn.Predicate`, and asks the engine to generate matching deals — the Odin
	equivalent of a `deal` Tcl condition script.

	The predicate here is deliberately SELF-CONTAINED, using `norn` primitives only, so the example
	stands alone as a library demo. A real bidding system's named predicates (`is_strong_1c` and
	friends) live in a separate consumer project that depends on norn as a library.

	Build/run from the repo root:  odin run examples/strong-1c.odin -file -out:target/debug/strong-1c.exe
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

import "../norn"

// A self-contained demo condition (norn primitives only): North holds a very strong, spade-heavy
// hand — 22+ hcp with a 7+ card spade suit.
north_opens_gf_strong_spades :: proc(board: norn.Deal) -> bool {
	north := board[.North]
	return norn.hcp(north) >= 22 && norn.spade_length(north) >= 7
}

main :: proc() {
	// Seed for a reproducible example run.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 1234)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Keep 10 matching deals; cap attempts so an over-restrictive condition can't loop forever.
	accepted, attempts := norn.generate_accepted(&builder, 10, .Line, north_opens_gf_strong_spades, 1_000_0000)
	fmt.eprintfln("strong-1c: accepted %d of %d deals tried", accepted, attempts)

	os.write_string(os.stdout, strings.to_string(builder))
}
