package norn

/*
	summary.odin — a bitmask "index" of a hand, and the hot evaluation primitives over it.

	A `Hand` is 13 unordered cards, so the `evaluate.odin` primitives rescan all 13 on every query
	(`suit_length` loops 13; `top_count` loops n*13; `pattern` scans 52 + sorts). A predicate fires
	dozens of these, and reject sampling runs the predicate on millions of deals.

	A `HandSummary` is the per-suit index almost every query actually wants: four 16-bit masks, one
	per suit, with bit `r` set when the hand holds rank `r` (rank backing value 0..12). Built once
	from a hand in 13 ops, it turns the hot queries into popcount / AND / bit-test:

	  suit length   -> popcount(mask)
	  holds(r)      -> mask & (1<<r)
	  top_count(n)  -> popcount(mask & TOP_N)
	  hcp/controls  -> a few bit tests
	  pattern       -> 4 popcounts (+ sort of 4)

	This is order-free and deterministic — no sorting of the 13 cards is needed (sorting stays a
	render concern). The `s_*` procs here mirror the `evaluate.odin` ones exactly so a predicate can
	be written against either representation; `cmd/bench` measures the difference.
*/

import "base:intrinsics"

// Per-suit rank bitmasks. `suits[suit]` has bit `int(rank)` set iff the hand holds that card.
HandSummary :: struct {
	suits: [Suit]u16,
}

// A whole deal's worth of summaries, indexed by seat (parallel to `Deal`).
Deal_Summary :: [Seat]HandSummary

// Honour bits, by rank backing value (Ace=12 … Ten=8).
@(private = "file")
ACE_BIT :: u16(1) << u16(Rank.Ace)
@(private = "file")
KING_BIT :: u16(1) << u16(Rank.King)
@(private = "file")
QUEEN_BIT :: u16(1) << u16(Rank.Queen)
@(private = "file")
JACK_BIT :: u16(1) << u16(Rank.Jack)
@(private = "file")
TEN_BIT :: u16(1) << u16(Rank.Ten)

// Masks of the top n ranks (ace downward), indexed by n (0..5). `TOP_MASKS[2]` is A|K.
@(private = "file")
TOP_MASKS := [6]u16 {
	0,
	ACE_BIT,
	ACE_BIT | KING_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT,
	ACE_BIT | KING_BIT | QUEEN_BIT | JACK_BIT | TEN_BIT,
}

// Build the bitmask index for a hand (13 ops, once).
summarize :: proc(hand: Hand) -> HandSummary {
	s: HandSummary
	for card in hand {
		s.suits[card_suit(card)] |= u16(1) << u16(card_rank(card))
	}
	return s
}

// Build summaries for all four seats of a deal.
summarize_deal :: proc(board: Deal) -> Deal_Summary {
	ds: Deal_Summary
	for seat in Seat {
		ds[seat] = summarize(board[seat])
	}
	return ds
}

// --- The hot primitives, re-expressed over the index. Each mirrors its `evaluate.odin` twin. ---

s_suit_length :: proc(s: HandSummary, suit: Suit) -> int {
	return int(intrinsics.count_ones(s.suits[suit]))
}

s_spade_length :: proc(s: HandSummary) -> int {return s_suit_length(s, .Spades)}
s_heart_length :: proc(s: HandSummary) -> int {return s_suit_length(s, .Hearts)}
s_diamond_length :: proc(s: HandSummary) -> int {return s_suit_length(s, .Diamonds)}
s_club_length :: proc(s: HandSummary) -> int {return s_suit_length(s, .Clubs)}

s_holds :: proc(s: HandSummary, suit: Suit, rank: Rank) -> bool {
	return s.suits[suit] & (u16(1) << u16(rank)) != 0
}

s_hcp :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if m & ACE_BIT != 0 {total += 4}
		if m & KING_BIT != 0 {total += 3}
		if m & QUEEN_BIT != 0 {total += 2}
		if m & JACK_BIT != 0 {total += 1}
	}
	return total
}

s_controls :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		m := s.suits[suit]
		if m & ACE_BIT != 0 {total += 2}
		if m & KING_BIT != 0 {total += 1}
	}
	return total
}

s_top_count :: proc(s: HandSummary, suit: Suit, n: int) -> int {
	return int(intrinsics.count_ones(s.suits[suit] & TOP_MASKS[n]))
}

s_top5q :: proc(s: HandSummary, suit: Suit) -> int {
	m := s.suits[suit]
	high := ACE_BIT | KING_BIT | QUEEN_BIT
	low := JACK_BIT | TEN_BIT
	return 2 * int(intrinsics.count_ones(m & high)) + int(intrinsics.count_ones(m & low))
}

s_shape :: proc(s: HandSummary) -> [SUIT_COUNT]int {
	return [SUIT_COUNT]int {
		s_suit_length(s, .Spades),
		s_suit_length(s, .Hearts),
		s_suit_length(s, .Diamonds),
		s_suit_length(s, .Clubs),
	}
}

s_pattern :: proc(s: HandSummary) -> [SUIT_COUNT]int {
	lengths := s_shape(s)
	// Selection sort, descending — only four elements (matches `pattern`).
	for i in 0 ..< SUIT_COUNT {
		largest := i
		for j in i + 1 ..< SUIT_COUNT {
			if lengths[j] > lengths[largest] {
				largest = j
			}
		}
		lengths[i], lengths[largest] = lengths[largest], lengths[i]
	}
	return lengths
}

s_is_nt5cM_shape :: proc(s: HandSummary) -> bool {
	has_four := false
	has_five := false
	for suit in Suit {
		length := s_suit_length(s, suit)
		if length < 2 || length > 5 {
			return false
		}
		if length == 4 {has_four = true}
		if length == 5 {has_five = true}
	}
	return !(has_four && has_five)
}

// --- The remaining `evaluate.odin` / `evaluate_losers.odin` evaluators, mirrored over the index so
// a predicate written against `HandSummary` never has to fall back to the 13-card `Hand` scan. Each
// is the exact logic of its twin with `suit_length`/`holds` replaced by `s_suit_length`/`s_holds`. ---

// Mirror of `is_balanced`.
s_is_balanced :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	if sp >= 5 || h >= 5 {
		return false
	}
	return sp * sp + h * h + d * d + c * c <= 47
}

// Mirror of `is_semibalanced`.
s_is_semibalanced :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	return sp >= 2 && h >= 2 && d >= 2 && c >= 2 && sp <= 5 && h <= 5 && d <= 6 && c <= 6
}

// Mirror of `is_nt`.
s_is_nt :: proc(s: HandSummary, min, max: int) -> bool {
	if !s_is_balanced(s) {
		return false
	}
	points := s_hcp(s)
	return points >= min && points <= max
}

// Mirror of `is_spade_shape`.
s_is_spade_shape :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	return sp >= 5 && sp >= h && d <= sp && c <= sp
}

// Mirror of `is_heart_shape`.
s_is_heart_shape :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	return h >= 5 && sp < h && d <= h && c <= h
}

// Mirror of `is_diamond_shape`.
s_is_diamond_shape :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	return (sp < 5 || d > sp) && (h < 5 || d > h) && (d > c || (d == c && d >= 5))
}

// Mirror of `is_club_shape`.
s_is_club_shape :: proc(s: HandSummary) -> bool {
	sp := s_suit_length(s, .Spades)
	h := s_suit_length(s, .Hearts)
	d := s_suit_length(s, .Diamonds)
	c := s_suit_length(s, .Clubs)
	return (sp < 5 || c > sp) && (h < 5 || c > h) && (d < c || (d == c && c < 5))
}

// Mirror of `losers` (half-loser units; see the original's doc for the queen-backing quirk).
s_losers :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		length := s_suit_length(s, suit)
		if length == 0 {
			continue
		}
		ace := s_holds(s, suit, .Ace)
		king := s_holds(s, suit, .King)
		if !ace {
			total += 2
		}
		if length >= 2 && !king {
			total += 2
		}
		if length >= 3 {
			if !s_holds(s, suit, .Queen) {
				total += 2
			} else if !(ace || king || s_holds(s, suit, .Jack) || s_holds(s, suit, .Ten)) {
				total += 1
			}
		}
	}
	return total
}

// Mirror of `suit_top_weighted`: sum of `weights` over the top ranks held in `suit`, ace downward.
@(private = "file")
s_suit_top_weighted :: proc(s: HandSummary, suit: Suit, weights: []int) -> int {
	ranks := [7]Rank{.Ace, .King, .Queen, .Jack, .Ten, .Nine, .Eight}
	sum := 0
	for weight, i in weights {
		if s_holds(s, suit, ranks[i]) {
			sum += weight
		}
	}
	return sum
}

// Mirror of `offense`.
s_offense :: proc(s: HandSummary, suit: Suit) -> int {
	length := s_suit_length(s, suit)
	a := s_holds(s, suit, .Ace)
	k := s_holds(s, suit, .King)
	q := s_holds(s, suit, .Queen)
	j := s_holds(s, suit, .Jack)
	t := s_holds(s, suit, .Ten)
	n9 := s_holds(s, suit, .Nine)
	n8 := s_holds(s, suit, .Eight)
	ai := int(a); ki := int(k); qi := int(q); ji := int(j); ti := int(t); n9i := int(n9); n8i := int(n8)

	switch BASE_LOSERS[length] {
	case 0:
		return length
	case 1:
		return length - 1 + ai
	case 2:
		if a && k {return length}
		if a || (k && q) {return length - 1}
		return length - 2
	case 3:
		if a && k && q {return length}
		if (a && k) || ((a || k) && q && j) {return length - 1}
		if a || (k && q) {return length - 2}
		if (q || k) && j && (t || n9) {return length - 2}
		return length - 3
	case:
		if a && k && q && (j || t) {return length}
		if 3 * (ai + ki + qi + ji) + ti + n9i >= 10 {return length - 1}
		if 4 * (ai + ki + qi + ji) + ti + n9i + n8i >= 10 {return length - 2}
		if 20 * ai + 12 * ki + 12 * qi + 6 * ji + 2 * ti + n9i + n8i > 20 {return length - 3}
		return length - 4
	}
}

// Mirror of `defense` (half-units, like `s_losers`).
s_defense :: proc(s: HandSummary, suit: Suit) -> int {
	length := s_suit_length(s, suit)
	a := s_holds(s, suit, .Ace)
	k := s_holds(s, suit, .King)
	q := s_holds(s, suit, .Queen)
	j := s_holds(s, suit, .Jack)

	half := 0
	if a {half += 2}
	if k && length < 7 {half += 2}
	if k && length == 7 {half += 1}
	if q && length < 6 {
		if a || k {
			half += 2
		} else {
			half += 1
		}
	}
	if q && length == 6 && (a || k) {half += 1}
	if length <= 4 && a && k && !q && j {half += 1}
	return half
}

// Mirror of `op` (offensive potential of the whole hand).
s_op :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		total += s_offense(s, suit) - s_defense(s, suit)
	}
	return total
}

// Mirror of `dhcp` (distribution-adjusted high-card points).
s_dhcp :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		bucket := min(s_suit_length(s, suit), 3)
		total += s_suit_top_weighted(s, suit, DHCP_WEIGHTS[bucket][:])
	}
	return total
}

// Mirror of `new_ltc` (half-units).
s_new_ltc :: proc(s: HandSummary) -> int {
	total := 0
	for suit in Suit {
		length := s_suit_length(s, suit)
		if length == 0 {
			continue
		}
		if !s_holds(s, suit, .Ace) {total += 3}
		if length >= 2 && !s_holds(s, suit, .King) {total += 2}
		if length >= 3 && !s_holds(s, suit, .Queen) {total += 1}
	}
	return total
}
