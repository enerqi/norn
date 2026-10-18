package combo

/*
	aids.odin — combo-side helpers for the learner declarer-play aids (LEARNER_AIDS_PLAN.md B & C).

	B (suit-combination odds per line) and C (safety / min-variance line) both compare ALL candidate
	lines per suit and want two extra things the raw `Line_Summary` view (G1) doesn't carry:
	  * a PATTERN NAME for the suit — "two-way finesse", "8-ever/9-never", "one-way finesse"
	    (`combination_note`), read from the two known holdings' geometry, no solving; and
	  * the best line BY MEAN vs the best line BY FLOOR (the safety trade C teaches).

	`Suit_Combo_Advice` bundles both onto the G1 candidate slice so the text advisor builds B and C from
	one call. Everything here is solver-free (combo has no `deal_solve`/DDS dependency); the pattern geometry
	deliberately MIRRORS `deal_solve/tax.odin`'s `two_way_guess_pivots` so the note a suit shows lines up with the
	blind two-way guess the misguess-tax estimator prices (aids plan B3 cross-link).
*/

import "core:fmt"

import "../norn"

// Honour rank bit positions (Two=0 .. Ace=12), for the combination classifier.
@(private)
RANK_TEN :: 8
@(private)
RANK_JACK :: 9
@(private)
RANK_QUEEN :: 10
@(private)
RANK_KING :: 11
@(private)
RANK_ACE :: 12

// True iff `m` holds any rank strictly ABOVE `r` (a card that can lead/win over rank `r`).
@(private)
has_rank_above :: proc "contextless" (m: u16, r: int) -> bool {
	return (m >> uint(r + 1)) != 0
}

// The missing honours (Ten..King, as rank bits) declarer can finesse for EITHER WAY in one suit: THE definition
// of a two-way finesse, which the pattern note names and the misguess tax (`sampled.two_way_guess_pivots`)
// prices - one definition, so the two cannot drift apart (they were two copies of one rule, and the copies
// shared its bug). A missing honour C is two-way when declarer holds both its neighbours (a tight tenace) and
// EACH hand holds a card above C and a card of the run held just below it, to finesse with: AJx opposite KTx.
// A card above C in each hand is not enough - KJ85 opposite A4 has one finesse, low to the jack.
two_way_finesse_ranks :: proc "contextless" (north, south: u16) -> (ranks: u16) {
	ns := north | south
	for r := RANK_TEN; r <= RANK_KING; r += 1 {
		if ns & rank_bit(r) != 0 || ns & rank_bit(r + 1) == 0 || ns & rank_bit(r - 1) == 0 {
			continue // we hold C, or it is not trapped between two of our cards
		}
		if has_rank_above(north, r) &&
		   has_rank_above(south, r) &&
		   holds_run_below(north, ns, r) &&
		   holds_run_below(south, ns, r) {
			ranks |= rank_bit(r)
		}
	}
	return
}

// The two-way finesses that are real GUESSES: `two_way_finesse_ranks`, kept only when playing blind costs
// something in the suit - its best fixed line takes fewer tricks than double dummy on average. QJ86 opposite
// AK972 has the geometry for the ten but no guess: a 4-0 split shows on the first round, and either way is then
// covered. What the pattern note names and the misguess tax prices.
two_way_guesses :: proc(north, south: u16) -> u16 {
	ranks := two_way_finesse_ranks(north, south)
	if ranks == 0 {
		return 0
	}
	return ranks if blind_costs(north, south) else 0
}

// Whether playing the suit blind costs anything: its best fixed line takes fewer tricks on average than double
// dummy, by more than `GUESS_MIN_COST`. Where it does not, there is no finesse to name and no guess to price,
// whatever the cards look like (AJ opposite KT: the ace and king, two tricks, however it is played).
blind_costs :: proc(north, south: u16) -> bool {
	fixed := fixed_line_tables(north, south)
	return blind_costs_in(suit_joint_table(north, south), fixed[:])
}

// The same from tables already built: the suit's census table and each fixed line's (`annotate` has them all
// for the page, and valuing every line again for the note was 40% of a deal's analysis, measured 2026-10-18).
// `fixed` may run on past the fixed lines (the solver's line, last): only the first `N_CANDIDATE_LINES` count.
blind_costs_in :: proc(census: Suit_Joint_Table, fixed: []Line_Joint) -> bool {
	blind := f64(-1)
	for c in fixed[:min(len(fixed), N_CANDIDATE_LINES)] {
		blind = max(blind, expected_tricks(marginal_from_table(c.tbl).p))
	}
	return expected_tricks(marginal_from_table(census).p) - blind > GUESS_MIN_COST
}

// Each fixed line's joint table in a holding, in `candidate_lines` order.
@(private)
fixed_line_tables :: proc(north, south: u16) -> (out: [N_CANDIDATE_LINES]Line_Joint) {
	memo := make(map[u64]int)
	defer delete(memo)
	for line, i in candidate_lines() {
		out[i] = Line_Joint{line.name, sd_line_joint_table(north, south, line, &memo)}
	}
	return
}

// The smallest blind cost (tricks a deal, against double dummy) that counts as a guess.
GUESS_MIN_COST :: 0.005

// True iff `hand` holds a card of the run the partnership `held` holds directly below rank `r` (r-1, r-2, ...
// down to the first rank neither hand has): a card to finesse WITH against a missing `r`.
@(private)
holds_run_below :: proc "contextless" (hand, held: u16, r: int) -> bool {
	for k := r - 1; k >= 0 && held & rank_bit(k) != 0; k -= 1 {
		if hand & rank_bit(k) != 0 {
			return true
		}
	}
	return false
}

// Name the standard suit-combination PATTERN in the two known holdings, or "" when none applies. Read from
// card geometry, and only for a suit with something to play for: double dummy takes more tricks on some layouts
// than others, or playing blind costs something (AJ2 opposite KT3 is always three tricks double dummy, but a
// guess blind). AJ opposite KT, and QJ86 opposite AK972, take the same tricks every way: no finesse to name. Priority: two-way finesse (the costliest blind
// guess) → 8-ever/9-never (a length-decided hook) → one-way finesse. The two-way test mirrors
// `deal_solve/tax.odin` exactly, so the phrase aligns with the priced misguess tax.
combination_note :: proc(north, south: u16) -> string {
	if north | south == 0 {
		return ""
	}
	fixed := fixed_line_tables(north, south)
	return combination_note_in(north, south, suit_joint_table(north, south), fixed[:])
}

// `combination_note` from tables already built (`blind_costs_in`).
combination_note_in :: proc(north, south: u16, census_table: Suit_Joint_Table, fixed: []Line_Joint) -> string {
	ns := north | south
	ns_len := card_count(ns)
	if ns_len == 0 {
		return ""
	}

	census := marginal_from_table(census_table)
	costs := blind_costs_in(census_table, fixed)
	if census.p[sure_tricks(census.p)] > 1 - 1e-12 && !costs {
		return ""
	}
	// Two-way finesse (`two_way_guesses`): name the top such guess.
	two_way := two_way_finesse_ranks(north, south) if costs else 0
	for r := RANK_KING; r >= RANK_TEN; r -= 1 {
		if two_way & rank_bit(r) != 0 {
			return fmt.tprintf("two-way finesse — guess which defender holds the %s", RANK_NAMES[r])
		}
	}

	// 8-ever / 9-never: A, K and J held with the queen missing — a one-way hook whose right answer flips on
	// combined length (nine cards → play for the drop; eight → finesse the jack).
	// Only at eight and nine cards: shorter is a plain finesse (below), longer a plain drop.
	if (ns_len == 8 || ns_len == 9) &&
	   ns & rank_bit(RANK_ACE) != 0 &&
	   ns & rank_bit(RANK_KING) != 0 &&
	   ns & rank_bit(RANK_JACK) != 0 &&
	   ns & rank_bit(RANK_QUEEN) == 0 {
		if ns_len == 9 {
			return "9-never — cash A K and play for the queen to drop"
		}
		return "8-ever — finesse the jack for the missing queen"
	}

	// One-way finesse: a missing honour trapped by a tenace (both neighbours held) but attackable from only
	// one side. Name the honour that must be onside.
	for r := RANK_KING; r >= RANK_QUEEN; r -= 1 {
		if ns & rank_bit(r) != 0 {
			continue
		}
		above := ns & rank_bit(r + 1) != 0
		below := r > 0 && ns & rank_bit(r - 1) != 0
		if above && below {
			return fmt.tprintf("finesse — needs the %s onside", RANK_NAMES[r])
		}
	}
	return ""
}

// Everything B and C need for ONE suit: the full candidate view (G1), the index of the best line by MEAN
// (the card page's recommendation) and by FLOOR (the max-guaranteed safety line), and the pattern note.
Suit_Combo_Advice :: struct {
	cands:          []Line_Summary, // every candidate line (mean + guaranteed floor); caller owns it
	best_mean_idx:  int, // index into `cands` of the highest-mean line (matches Sd_Bundle's pick)
	best_floor_idx: int, // index of the highest-guaranteed-floor line (ties → higher mean)
	note:           string, // combination pattern phrase, or "" (temp-allocated by `combination_note`)
	north_holding:  u16, // this suit's NS holdings — so C can run the optimal-line search (below) lazily
	south_holding:  u16,
}

// Per-suit combination advice for a known partnership, in DISPLAY_SUITS order (s,h,d,c). Builds on the G1
// candidate view (`suit_line_summaries`) and adds the best-by-mean / best-by-floor picks + the pattern
// note. Caller owns each `cands` slice (allocated from `allocator`).
suit_combo_advice :: proc(north, south: norn.Hand_Summary, allocator := context.allocator) -> [4]Suit_Combo_Advice {
	out: [4]Suit_Combo_Advice
	cands4 := suit_line_summaries(north, south, allocator)
	for suit, i in DISPLAY_SUITS {
		cs := cands4[i]
		bm, bf := 0, 0
		for ls, j in cs {
			if ls.mean > cs[bm].mean {
				bm = j // first-wins on ties (strict >), matching Sd_Bundle's best-by-mean pick
			}
			if ls.floor > cs[bf].floor || (ls.floor == cs[bf].floor && ls.mean > cs[bf].mean) {
				bf = j
			}
		}
		out[i] = Suit_Combo_Advice {
			cands          = cs,
			best_mean_idx  = bm,
			best_floor_idx = bf,
			note           = combination_note(norn.suit_mask(north, suit), norn.suit_mask(south, suit)),
			north_holding  = norn.suit_mask(north, suit),
			south_holding  = norn.suit_mask(south, suit),
		}
	}
	return out
}

// --- F (entry / timing heuristic) — LEARNER_AIDS_PLAN.md F -------------------------------------
//
// The naive model assumes FREE ENTRIES. These three geometry-only helpers let the text advisor partly
// walk that back: warn when a suit's recommended FINESSE must be led from one hand more than once, but
// that hand has few outside entries to get back there. Crude on purpose (a real entry count needs the
// whole-hand play); the F warning stays conservative and is tagged HEURISTIC.

// The seat a finesse in this suit must be LED FROM (repeatedly): the hand OPPOSITE the honour hand (the
// seat holding the single highest NS card). The finesse machinery leads low from here toward the honour.
finesse_leading_seat :: proc(north, south: u16) -> int {
	hon := strong_honour_seat(north, south)
	return SEAT_S if hon == SEAT_N else SEAT_N
}

// Crude count of finesse leads a suit needs = missing (opponent-held) ranks INTERIOR to the honour
// hand's span — a card sitting between the honour hand's lowest and highest card, which you must lead
// toward the honour hand to trap. Each interior gap is one such lead, so 2+ means a REPEATED finesse
// (AJT missing K,Q → 2), the case where a short entry to the leading hand actually bites. A solid run
// (AKQ) has no interior gap → 0. Geometry only, no solving.
finesse_leads_needed :: proc(north, south: u16) -> int {
	ns := north | south
	hon := strong_honour_seat(north, south)
	hon_hold := north if hon == SEAT_N else south
	if card_count(hon_hold) < 2 {
		return 0 // a finesse needs a tenace (2+ cards spanning a gap)
	}
	top := highest_rank(hon_hold)
	bot := lowest_rank(hon_hold)
	n := 0
	for r := bot + 1; r < top; r += 1 {
		if ns & rank_bit(r) == 0 { 	// an opponent card inside the honour hand's span — a finesse target
			n += 1
		}
	}
	return n
}

// Sure quick entries to a hand from its SIDE suits (all but `exclude`, DISPLAY_SUITS order): the top
// solid run down from the ace in each other suit (A→1, AK→2, AKQ→3 …). A crude HIGH-CARD entry count —
// it ignores ruffing entries (no trump suit in view here) and long-card entries, so it UNDER-counts;
// the F warning is deliberately conservative for that reason.
sure_side_entries :: proc(suits: [4]u16, exclude: int) -> int {
	total := 0
	for hold, i in suits {
		if i == exclude {
			continue
		}
		for r := RANK_ACE; r >= 0; r -= 1 {
			if hold & rank_bit(r) == 0 {
				break // first gap from the top ends the solid run
			}
			total += 1
		}
	}
	return total
}

// Board wrapper for `suit_combo_advice` — same known-side resolution and `ok` contract as
// `sd_bundle_board`. The B/C entry point for the 2-hand text advisor.
suit_combo_advice_board :: proc(
	board: norn.Board,
	allocator := context.allocator,
) -> (
	advice: [4]Suit_Combo_Advice,
	side: bit_set[norn.Seat],
	ok: bool,
) {
	n, s, resolved, k := board_partnership(board)
	if !k {
		return {}, {}, false
	}
	return suit_combo_advice(n, s, allocator), resolved, true
}
