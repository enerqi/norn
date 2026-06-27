package norn

/*
	shuffle.odin — random number generation and the shuffle.

	RANDOMNESS
	----------
	We use Odin's standard library generator `xoshiro256**` (`core:math/rand`). It is small, fast,
	and statistically strong — ideal for shuffling cards. It is NOT cryptographic; never use it
	where unpredictability matters for security.

	Odin's `rand` package draws from `context.random_generator`, an implicit per-context value. The
	program installs a generator once (see `seeded_xoshiro`) and every `rand.*` call below it —
	including this shuffle — then draws from that stream. This keeps the shuffle itself free of any
	explicit generator plumbing.

	REPRODUCIBILITY
	---------------
	Seeding the generator with a fixed value makes every deal reproducible: the same seed yields
	byte-for-byte identical boards forever. That makes bugs reproducible, lets tests assert exact
	output, and lets a user re-create a specific set of practice hands. Seeding is done with
	`rand.reset(seed)`; a run with no user seed can pick (and log) one so it can still be replayed.
*/

import "core:math/rand"

// Return a `xoshiro256**` generator backed by `state` and seeded with `seed`, ready to install:
//
//	state: rand.Xoshiro256_Random_State
//	context.random_generator = seeded_xoshiro(&state, seed)
//
// `state` is owned by the caller and must outlive the generator's use. Taking the state explicitly
// (rather than the library's shared thread-local default) means independent streams — e.g. one per
// worker thread when deal generation is parallelised later — never interfere with each other.
seeded_xoshiro :: proc(state: ^rand.Xoshiro256_Random_State, seed: u64) -> rand.Generator {
	generator := rand.xoshiro256_random_generator(state)
	rand.reset(seed, generator) // seed this generator specifically, not the context default
	return generator
}

// Shuffle `cards` in place into a uniformly random permutation using the Fisher–Yates algorithm,
// drawing from `context.random_generator`.
//
// Walking from the last index down to the second, we swap each card with one chosen uniformly from
// the cards at or before it (indices 0..=i). The key to uniformity is that the random index range
// SHRINKS by one each step: every one of the n! orderings results from exactly one sequence of
// choices, so all are equally likely. (A common bug is picking j from the full range 0..<n every
// time — that does NOT give a uniform shuffle.)
//
// `rand.int_max(i + 1)` yields a uniform value in [0, i] (it returns [0, n) and is itself free of
// modulo bias).
shuffle :: proc(cards: []Card) {
	for i := len(cards) - 1; i > 0; i -= 1 {
		j := rand.int_max(i + 1)
		cards[i], cards[j] = cards[j], cards[i]
	}
}
