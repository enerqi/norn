package main

/*
	examples/strong-1c — a single-condition generator program.

	This is the shape every deal simulation will take: a tiny `package main` that imports the `norn`
	engine and the `conditions` library, defines a `norn.Predicate`, and asks the engine to generate
	matching deals. It is the Odin equivalent of a `deal` Tcl condition script like `3n-opener.tcl`.

	Build/run from the repo root:  odin run examples/strong-1c -out:target/debug/strong-1c.exe
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

import "../../conditions"
import "../../norn"

// The condition: North holds a strong, artificial 1C opening.
north_opens_strong_1c :: proc(board: norn.Deal) -> bool {
	return conditions.is_strong_1c(board[.North])
}

main :: proc() {
	// Seed for a reproducible example run.
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, 1234)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Keep 10 matching deals; cap attempts so an over-restrictive condition can't loop forever.
	accepted, attempts := norn.generate_accepted(&builder, 10, .Line, north_opens_strong_1c, 1_000_000)
	fmt.eprintfln("strong-1c: accepted %d of %d deals tried", accepted, attempts)

	os.write_string(os.stdout, strings.to_string(builder))
}
