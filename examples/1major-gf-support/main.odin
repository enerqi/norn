package main

/*
	examples/1major-gf-support — a multi-seat opener+responder generator.

	The Odin port of `deal-simulations/1major-gf-3plus-card-support.tcl`:

		main {
		  if {[is_1major_opener north] && [hcp south]>=13 && [has_major_support north south 3]} { accept }
		  reject
		}

	North opens a limited 1-major; South holds a game-forcing 13+ with at least three-card support
	for North's major. Unlike `strong-1c` (a single seat), this condition reads TWO hands of the
	deal, so the `norn.Predicate` reaches into both `board[.North]` and `board[.South]`.

	Build/run from the repo root: odin run examples/1major-gf-support -out:target/debug/1major-gf.exe
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"

import "../../conditions"
import "../../norn"

// The condition: North opens a 1-major and South has a game-forcing hand with 3+ card support.
north_opens_south_raises :: proc(board: norn.Deal) -> bool {
	north := board[.North]
	south := board[.South]
	return conditions.is_1major_opener(north) && norn.hcp(south) >= 13 && conditions.has_major_support(north, south, 3)
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
