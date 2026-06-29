package norn

/*
	smartstack.odin — shape- and strength-biased generation for one seat ("SmartStack").

	WHY
	---
	Reject sampling (see generate.odin) is fine until a condition is rare. A seat that must be, say,
	balanced AND 20-21 hcp is accepted on well under 1% of random deals, so the loop throws away
	hundreds of boards per keeper. SmartStack instead builds that ONE seat's hand DIRECTLY from the
	constraint — never dealing a hand that fails it — while keeping the hand uniformly distributed
	over all hands that satisfy it. (redeal calls this SmartStack; dealer calls the cruder version
	"predeal". DESIGN.md notes this is the real lever for rare hands, not raw speed.)

	The trick is exact importance sampling. A constraint here is "shape in this set AND hcp in
	[lo,hi]". We can COUNT, in closed form, how many 13-card hands match — and the per-suit pieces
	that make up that count — so we can sample a matching hand with exactly its conditional
	probability:

	  1. pick a shape (s-h-d-c lengths) in proportion to how many in-range hands have that shape;
	  2. pick a total hcp t in [lo,hi] in proportion to how many hands of that shape have t points;
	  3. split t across the four suits in proportion to the joint honour-count;
	  4. per suit, pick which honours are held (in proportion to the spot-card fillings) then deal
	     the remaining low cards at random.

	The result is a hand drawn uniformly from {shape in set} ∩ {hcp in [lo,hi]}. The rest of the deck
	is dealt at random to the other three seats. Any FURTHER condition (other seats, finer tests on
	this one) is still applied by reject sampling on top — but the expensive rare part is gone.

	SCOPE
	-----
	v1 biases a single seat by shape-set + hcp-range, with hcp (4-3-2-1) as the evaluator. That
	covers the dominant rare-hand case. A general per-rank point vector and multi-seat stacking are
	possible later (the honour-distribution machinery here generalises), but are deliberately out for
	now to keep the core small.

	HCP DECOMPOSITION
	-----------------
	Within one suit the 13 cards split into 4 honours — J,Q,K,A worth 1,2,3,4 — and 9 spot cards
	(2..T) worth nothing. A holding of length L with a chosen honour subset H (|H| honours, summing to
	`points`) fills its remaining L-|H| cards from the 9 spots in C(9, L-|H|) ways. So the number of
	length-L holdings worth exactly p points is the sum of C(9, L-|H|) over honour subsets H summing to
	p — `suit_hcp_table` below. Convolving four such per-suit distributions gives a whole hand's hcp
	distribution for a fixed shape; that convolution is the source of every weight used in sampling.

	The spec is heap-free (fixed arrays, like Predeal), so it is cheap to copy and safe to share
	across the worker threads that drive frequency measurement. Build it once with `smartstack_make`
	(or `smartstack_make_filtered`), then deal repeatedly with `deal_board_smartstack`. Drawing always
	uses `context.random_generator`, like the rest of the engine.
*/

import "core:math/rand"

// Largest hcp a single suit can hold: A+K+Q+J = 4+3+2+1.
MAX_SUIT_HCP :: 10

// Largest hcp a whole hand can hold: four full-honour suits. (40 — the classic "all the points".)
@(private = "file")
TOTAL_HCP_MAX :: SUIT_COUNT * MAX_SUIT_HCP

// Honours in a suit are the four cards that carry hcp, plus 9 spot cards that carry none.
@(private = "file")
HONORS_PER_SUIT :: 4
@(private = "file")
SPOTS_PER_SUIT :: RANK_COUNT - HONORS_PER_SUIT // 9 (Two..Ten)

// The number of distinct s-h-d-c length compositions of 13 cards into 4 suits: C(13+3, 3) = 560.
// A SmartStack's shape set can hold at most this many (every possible shape).
MAX_SHAPES :: 560

// suit_hcp_table[L][p] = number of length-L holdings in a single suit worth exactly p hcp.
// Indexed by length 0..13 and points 0..10. The kernel everything else is built from.
Suit_Hcp_Table :: [RANK_COUNT + 1][MAX_SUIT_HCP + 1]i64

// The four honour ranks (low to high) and their hcp values; index i pairs HONOR_RANKS[i] with
// HONOR_VALUES[i]. Used both to weigh honour subsets and to materialise the chosen honours as cards.
@(private = "file")
HONOR_RANKS := [HONORS_PER_SUIT]Rank{.Jack, .Queen, .King, .Ace}
@(private = "file")
HONOR_VALUES := [HONORS_PER_SUIT]int{1, 2, 3, 4}

// The nine spot ranks (no hcp), the pool the low cards of every holding are drawn from.
@(private = "file")
SPOT_RANKS := [SPOTS_PER_SUIT]Rank{.Two, .Three, .Four, .Five, .Six, .Seven, .Eight, .Nine, .Ten}

// Binomial coefficients C(9, k) for k = 0..9 — the number of ways to choose the spot cards that fill
// out a holding. `binom9` guards the out-of-range k (no holding can use more than 9 spots).
@(private = "file")
C9 := [SPOTS_PER_SUIT + 1]i64{1, 9, 36, 84, 126, 126, 84, 36, 9, 1}

@(private = "file")
binom9 :: proc(k: int) -> i64 {
	if k < 0 || k > SPOTS_PER_SUIT {
		return 0
	}
	return C9[k]
}

// A built SmartStack spec: which seat to bias, the hcp window, and the candidate shapes with their
// pre-computed weights (in-range hand counts). `total_weight` is the sum of `weights`, the count of
// all hands the constraint admits. The `table` is cached so sampling needs no re-derivation. Plain
// value, no heap — copy or share freely.
Smart_Stack :: struct {
	seat:         Seat,
	hcp_min:      int,
	hcp_max:      int,
	shapes:       [MAX_SHAPES][SUIT_COUNT]int,
	weights:      [MAX_SHAPES]i64,
	shape_count:  int,
	total_weight: i64,
	table:        Suit_Hcp_Table,
}

// Build the suit hcp kernel (see file header). For each of the 16 honour subsets, add its
// C(9, L-|H|) fillings to every length L that can hold it.
build_suit_hcp_table :: proc() -> (table: Suit_Hcp_Table) {
	for mask in 0 ..< (1 << HONORS_PER_SUIT) {
		value := 0
		honors := 0
		for bit in 0 ..< HONORS_PER_SUIT {
			if (mask & (1 << uint(bit))) != 0 {
				value += HONOR_VALUES[bit]
				honors += 1
			}
		}
		for length in honors ..= RANK_COUNT {
			spots := length - honors
			if spots <= SPOTS_PER_SUIT {
				table[length][value] += binom9(spots)
			}
		}
	}
	return
}

// Convolve `a` and `b` (length distributions) into `out`, which is zeroed first. `out` must be long
// enough to hold indices up to len(a)+len(b)-2. Used to combine per-suit hcp distributions into a
// whole-hand (or partial-hand) distribution.
@(private = "file")
convolve :: proc(a, b, out: []i64) {
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	for i in 0 ..< len(a) {
		if a[i] == 0 {
			continue
		}
		for j in 0 ..< len(b) {
			if i + j < len(out) {
				out[i + j] += a[i] * b[j]
			}
		}
	}
}

// The hcp distribution of a whole hand of the given shape: dist[t] = number of hands of that shape
// worth exactly t hcp (t = 0..40). Built by convolving the four suits' length-fixed distributions.
shape_distribution :: proc(table: ^Suit_Hcp_Table, shape: [SUIT_COUNT]int) -> [TOTAL_HCP_MAX + 1]i64 {
	dist: [TOTAL_HCP_MAX + 1]i64
	dist[0] = 1 // empty hand: one way to have 0 points
	for suit_index in 0 ..< SUIT_COUNT {
		row := table[shape[suit_index]]
		next: [TOTAL_HCP_MAX + 1]i64
		convolve(dist[:], row[:], next[:])
		dist = next
	}
	return dist
}

// How many hands of `shape` fall in the hcp window [lo, hi] — the shape's sampling weight.
@(private = "file")
shape_weight :: proc(table: ^Suit_Hcp_Table, shape: [SUIT_COUNT]int, lo, hi: int) -> (weight: i64) {
	dist := shape_distribution(table, shape)
	for t in lo ..= hi {
		weight += dist[t]
	}
	return
}

// Enumerate every s-h-d-c length composition of 13 cards into 4 suits (560 of them). The building
// block for filtering shapes by a predicate.
enumerate_shapes :: proc() -> (shapes: [MAX_SHAPES][SUIT_COUNT]int, count: int) {
	for s in 0 ..= HAND_SIZE {
		for h in 0 ..= HAND_SIZE - s {
			for d in 0 ..= HAND_SIZE - s - h {
				c := HAND_SIZE - s - h - d
				shapes[count] = {s, h, d, c}
				count += 1
			}
		}
	}
	return
}

// Build a SmartStack from an explicit list of s-h-d-c shapes and an hcp window. The hcp range is
// clamped to [0, 40]. Shapes whose lengths don't sum to 13 (or fall outside 0..13) make the build
// fail. Shapes with zero in-range hands are dropped silently. `ok` is false if NO admitted hand
// exists (an impossible constraint) — callers must check it, since sampling an empty spec is
// undefined.
smartstack_make :: proc(
	seat: Seat,
	shapes: [][SUIT_COUNT]int,
	hcp_min: int,
	hcp_max: int,
) -> (
	ss: Smart_Stack,
	ok: bool,
) {
	ss.seat = seat
	ss.hcp_min = clamp(hcp_min, 0, TOTAL_HCP_MAX)
	ss.hcp_max = clamp(hcp_max, 0, TOTAL_HCP_MAX)
	if ss.hcp_min > ss.hcp_max {
		return {}, false
	}
	ss.table = build_suit_hcp_table()
	for shape in shapes {
		sum := 0
		for length in shape {
			if length < 0 || length > HAND_SIZE {
				return {}, false
			}
			sum += length
		}
		if sum != HAND_SIZE {
			return {}, false
		}
		if ss.shape_count >= MAX_SHAPES {
			return {}, false
		}
		weight := shape_weight(&ss.table, shape, ss.hcp_min, ss.hcp_max)
		if weight > 0 {
			ss.shapes[ss.shape_count] = shape
			ss.weights[ss.shape_count] = weight
			ss.shape_count += 1
			ss.total_weight += weight
		}
	}
	ok = ss.total_weight > 0
	return
}

// Build a SmartStack from every shape that `keep` accepts (plus the hcp window). A convenience over
// `smartstack_make` for expressing shapes as a rule rather than a list — e.g. `keep` returns true
// for balanced lengths, or for any 5+ card major. `keep` receives lengths in s-h-d-c order.
smartstack_make_filtered :: proc(
	seat: Seat,
	keep: proc(shape: [SUIT_COUNT]int) -> bool,
	hcp_min: int,
	hcp_max: int,
) -> (
	ss: Smart_Stack,
	ok: bool,
) {
	all, count := enumerate_shapes()
	chosen: [MAX_SHAPES][SUIT_COUNT]int
	chosen_count := 0
	for i in 0 ..< count {
		if keep(all[i]) {
			chosen[chosen_count] = all[i]
			chosen_count += 1
		}
	}
	return smartstack_make(seat, chosen[:chosen_count], hcp_min, hcp_max)
}

// Pick an index into `weights` with probability proportional to its weight. Returns -1 if every
// weight is zero. Drives every random choice in the sampler.
@(private = "file")
weighted_pick :: proc(weights: []i64) -> int {
	total: i64
	for w in weights {
		total += w
	}
	if total <= 0 {
		return -1
	}
	target := rand.float64() * f64(total)
	acc: i64
	for w, i in weights {
		acc += w
		if target < f64(acc) {
			return i
		}
	}
	return len(weights) - 1 // float rounding fell off the end; the last positive bucket
}

// Append a single suit's holding — `length` cards worth `points` hcp — into `hand` at `n`, advancing
// `n`. The honours are chosen among the subsets that hit `points` (weighted by their spot fillings),
// then the remaining low cards are drawn at random from the 9 spots via a partial Fisher–Yates.
@(private = "file")
sample_suit_holding :: proc(suit: Suit, length, points: int, hand: ^Hand, n: ^int) {
	// Collect the honour subsets that sum to `points` and fit in `length`, weighted by C(9, spots).
	masks: [1 << HONORS_PER_SUIT]int
	weights: [1 << HONORS_PER_SUIT]i64
	choices := 0
	for mask in 0 ..< (1 << HONORS_PER_SUIT) {
		value := 0
		honors := 0
		for bit in 0 ..< HONORS_PER_SUIT {
			if (mask & (1 << uint(bit))) != 0 {
				value += HONOR_VALUES[bit]
				honors += 1
			}
		}
		if value == points && honors <= length {
			weight := binom9(length - honors)
			if weight > 0 {
				masks[choices] = mask
				weights[choices] = weight
				choices += 1
			}
		}
	}

	mask := masks[weighted_pick(weights[:choices])]
	honors := 0
	for bit in 0 ..< HONORS_PER_SUIT {
		if (mask & (1 << uint(bit))) != 0 {
			hand[n^] = make_card(suit, HONOR_RANKS[bit])
			n^ += 1
			honors += 1
		}
	}

	// Draw the remaining low cards: shuffle the first `spots` of the spot pool and take them.
	spots := length - honors
	pool := SPOT_RANKS
	for i in 0 ..< spots {
		j := i + rand.int_max(SPOTS_PER_SUIT - i)
		pool[i], pool[j] = pool[j], pool[i]
		hand[n^] = make_card(suit, pool[i])
		n^ += 1
	}
}

// Sample one hand satisfying the SmartStack constraint, uniformly over all such hands (see the file
// header for why the four weighted picks compose into a uniform draw). Assumes `ss.ok` was true.
smartstack_hand :: proc(ss: ^Smart_Stack) -> Hand {
	// 1. shape, weighted by its count of in-range hands.
	shape := ss.shapes[weighted_pick(ss.weights[:ss.shape_count])]

	// 2. total hcp t in [lo, hi], weighted by how many hands of this shape have t points.
	dist := shape_distribution(&ss.table, shape)
	t_weights: [TOTAL_HCP_MAX + 1]i64
	for t in ss.hcp_min ..= ss.hcp_max {
		t_weights[t] = dist[t]
	}
	t := weighted_pick(t_weights[:]) // the chosen index IS the hcp value

	// 3. split t across the suits. Sample each suit's points in turn, weighted by its own count
	//    times the count of all ways the remaining suits can make up the rest (suffix convolutions).
	rows: [SUIT_COUNT][MAX_SUIT_HCP + 1]i64
	for i in 0 ..< SUIT_COUNT {
		rows[i] = ss.table[shape[i]]
	}
	// suffix[i] = hcp distribution of suits i..3 combined; suffix[3] is just suit 3's row.
	suffix2: [TOTAL_HCP_MAX + 1]i64
	convolve(rows[2][:], rows[3][:], suffix2[:])
	suffix1: [TOTAL_HCP_MAX + 1]i64
	convolve(rows[1][:], suffix2[:], suffix1[:])

	points: [SUIT_COUNT]int
	rem := t
	points[0] = pick_suit_points(rows[0][:], suffix1[:], rem)
	rem -= points[0]
	points[1] = pick_suit_points(rows[1][:], suffix2[:], rem)
	rem -= points[1]
	points[2] = pick_suit_points(rows[2][:], rows[3][:], rem)
	rem -= points[2]
	points[3] = rem // whatever is left goes to the last suit

	// 4. materialise each suit's holding.
	hand: Hand
	n := 0
	suits := [SUIT_COUNT]Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	for i in 0 ..< SUIT_COUNT {
		sample_suit_holding(suits[i], shape[i], points[i], &hand, &n)
	}
	return hand
}

// Choose this suit's hcp p (0..10) given that the suit and the suits after it must together make
// `rem` points. Weight of p is `row[p]` (ways for this suit) times `rest[rem-p]` (ways for the rest).
@(private = "file")
pick_suit_points :: proc(row, rest: []i64, rem: int) -> int {
	weights: [MAX_SUIT_HCP + 1]i64
	for p in 0 ..= MAX_SUIT_HCP {
		need := rem - p
		if p <= rem && need < len(rest) {
			weights[p] = row[p] * rest[need]
		}
	}
	return weighted_pick(weights[:])
}

// Deal one board with `ss`'s seat stacked to its constraint and the remaining 39 cards dealt at
// random to the other three seats. The stacked hand is uniform over the admitted hands; the rest is
// a uniform deal of what's left (exactly as predeal does). Drawing from `context.random_generator`.
deal_board_smartstack :: proc(ss: ^Smart_Stack) -> Deal {
	hand := smartstack_hand(ss)

	used: [DECK_SIZE]bool
	for card in hand {
		used[int(card)] = true
	}
	pool: [DECK_SIZE]Card
	pool_len := 0
	for i in 0 ..< DECK_SIZE {
		if !used[i] {
			pool[pool_len] = Card(i)
			pool_len += 1
		}
	}
	shuffle(pool[:pool_len])

	board: Deal
	board[ss.seat] = hand
	pi := 0
	for seat_index in 0 ..< SEAT_COUNT {
		seat := Seat(seat_index)
		if seat == ss.seat {
			continue
		}
		for k in 0 ..< HAND_SIZE {
			board[seat][k] = pool[pi]
			pi += 1
		}
	}
	return board
}
