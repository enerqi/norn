package main

/*
	run.odin — the CLI's generation driver.

	This is the application-policy layer that sits on top of the reusable `norn` library: it picks a
	seed, drives `norn.render_deals`, and writes the result to stdout or a file. The library stays
	I/O-free; everything here is the program's choice of how to seed and where to send output.
*/

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"

import "../../norn"

// Carry out the full generation requested by `opts`: seed the generator, render the deals, and
// write them to the chosen output. Returns ok = false with a message on an output error.
run :: proc(opts: Options) -> (ok: bool, message: string) {
	// Choose the seed. An explicit --seed makes the run reproducible; otherwise we pick a fresh one
	// from the clock and report it on stderr so this exact run can be reproduced later with --seed.
	seed := opts.seed
	if !opts.has_seed {
		seed = fresh_seed()
		fmt.eprintfln("norn: seed=%d (pass --seed %d to reproduce)", seed, seed)
	}

	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	norn.render_deals(&builder, opts.count, opts.format)

	return write_output(opts.output, strings.to_string(builder))
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
