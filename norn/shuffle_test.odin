package norn

/*
	shuffle_test.odin — unit tests for seeding and the shuffle.

	Each test installs its own seeded xoshiro256** generator into the context (with an explicit,
	test-local state) so the tests are independent and reproducible regardless of the order or
	thread the test runner uses.
*/

import "core:math/rand"
import "core:testing"

// Seeding with the same value must reproduce the exact same stream of values.
@(test)
test_seed_is_deterministic :: proc(t: ^testing.T) {
	state_a, state_b: rand.Xoshiro256_Random_State
	gen_a := seeded_xoshiro(&state_a, 12345)
	gen_b := seeded_xoshiro(&state_b, 12345)
	for _ in 0 ..< 1000 {
		testing.expect_value(t, rand.uint64(gen_a), rand.uint64(gen_b))
	}
}

// Different seeds should produce different streams (a smoke test, not a statistical proof).
@(test)
test_different_seeds_differ :: proc(t: ^testing.T) {
	state_a, state_b: rand.Xoshiro256_Random_State
	gen_a := seeded_xoshiro(&state_a, 1)
	gen_b := seeded_xoshiro(&state_b, 2)
	differences := 0
	for _ in 0 ..< 100 {
		if rand.uint64(gen_a) != rand.uint64(gen_b) {
			differences += 1
		}
	}
	testing.expect(t, differences > 90, "streams from different seeds barely differ")
}

// A shuffle is a permutation: it must reorder the deck without adding, dropping, or duplicating
// any card. We verify the multiset of cards is unchanged (still all 52, each once).
@(test)
test_shuffle_preserves_deck :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 2024)

	deck := full_deck()
	shuffle(deck[:])

	seen: [DECK_SIZE]bool
	for card in deck {
		idx := int(card)
		testing.expect(t, idx >= 0 && idx < DECK_SIZE, "card out of range after shuffle")
		testing.expect(t, !seen[idx], "duplicate card after shuffle")
		seen[idx] = true
	}
	for was_seen, idx in seen {
		testing.expectf(t, was_seen, "card %d lost during shuffle", idx)
	}
}

// The same seed must produce the same shuffled order.
@(test)
test_shuffle_is_deterministic :: proc(t: ^testing.T) {
	deck_a := full_deck()
	deck_b := full_deck()

	state_a: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_a, 7)
	shuffle(deck_a[:])

	state_b: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state_b, 7)
	shuffle(deck_b[:])

	for i in 0 ..< DECK_SIZE {
		testing.expect_value(t, deck_a[i], deck_b[i])
	}
}

// A shuffle should actually change the order (overwhelmingly likely for 52 cards). Guards against
// a no-op shuffle bug.
@(test)
test_shuffle_changes_order :: proc(t: ^testing.T) {
	state: rand.Xoshiro256_Random_State
	context.random_generator = seeded_xoshiro(&state, 555)

	original := full_deck()
	shuffled := original
	shuffle(shuffled[:])

	same_positions := 0
	for i in 0 ..< DECK_SIZE {
		if original[i] == shuffled[i] {
			same_positions += 1
		}
	}
	testing.expect(t, same_positions < DECK_SIZE, "shuffle left the deck completely unchanged")
}
