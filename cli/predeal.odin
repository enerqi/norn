package cli

/*
	predeal.odin — parsing the --predeal command-line spec into a `norn.Predeal`.

	Spec grammar (whitespace-separated groups, one per seat):

		SEAT:card[,card...]   e.g.  N:AS,KS  S:QH,JH

	SEAT is one of N E S W (case-insensitive); each card is a rank+suit label (see norn.parse_card),
	e.g. AS = ace of spades, TH = ten of hearts, 2C = two of clubs. Pure (no I/O): problems are
	reported as ok = false with a message, like the rest of the parser.
*/

import "core:fmt"
import "core:strings"

import "../norn"

// Map a seat letter (N/E/S/W, case-insensitive) to a `norn.Seat`. Only the first byte is read.
parse_seat :: proc(text: string) -> (seat: norn.Seat, ok: bool) {
	if len(text) == 0 {
		return .North, false
	}
	switch text[0] {
	case 'N', 'n':
		return .North, true
	case 'E', 'e':
		return .East, true
	case 'S', 's':
		return .South, true
	case 'W', 'w':
		return .West, true
	}
	return .North, false
}

// Parse a full --predeal spec into a validated `norn.Predeal`. Returns ok = false with a message on
// a malformed group, an unknown seat, a bad card, a seat given more than 13 cards, or a card
// assigned to more than one seat.
parse_predeal :: proc(spec: string) -> (pd: norn.Predeal, ok: bool, message: string) {
	groups := strings.fields(spec)
	defer delete(groups)
	if len(groups) == 0 {
		return {}, false, "--predeal is empty"
	}

	for g in groups {
		colon := strings.index_byte(g, ':')
		if colon < 0 {
			return {}, false, fmt.tprintf("predeal group %q is missing the SEAT: prefix", g)
		}
		seat, seat_ok := parse_seat(g[:colon])
		if !seat_ok {
			return {}, false, fmt.tprintf("predeal: unknown seat %q (expected N, E, S or W)", g[:colon])
		}

		cards := strings.split(g[colon + 1:], ",")
		defer delete(cards)
		for raw in cards {
			tok := strings.trim_space(raw)
			if tok == "" {
				continue
			}
			card, card_ok := norn.parse_card(tok)
			if !card_ok {
				return {}, false, fmt.tprintf("predeal: %q is not a card (e.g. AS, TH, 2C)", tok)
			}
			if !norn.predeal_add(&pd, seat, card) {
				return {}, false, fmt.tprintf("predeal: %v is given more than %d cards", seat, norn.HAND_SIZE)
			}
		}
	}

	if valid, why := norn.predeal_validate(pd); !valid {
		return {}, false, why
	}
	return pd, true, ""
}
