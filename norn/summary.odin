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
