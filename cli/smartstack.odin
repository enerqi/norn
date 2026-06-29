package cli

/*
	smartstack.odin — parsing the --smartstack command-line spec into a `norn.Smart_Stack`.

	Spec grammar (three whitespace-separated parts; the third may itself contain spaces):

		SEAT  HCP  SHAPE[/SHAPE...]

	SEAT  one of N E S W (case-insensitive).
	HCP   the high-card-point window for the stacked seat:
	        lo-hi   a range, e.g. 15-17
	        N       exactly N
	        N+      N or more  (up to 40)
	        N-      N or fewer (down to 0)
	SHAPE one or more alternatives separated by '/'. A deal is stacked to a hand matching ANY
	      alternative. Each alternative is either a keyword or a four-field length pattern:
	        keyword:  balanced | semibalanced | any
	        pattern:  four comma-separated suit-length fields in S,H,D,C order, each one of
	                    N     exactly N        (0..13, two digits allowed, e.g. 10)
	                    N+    N or more
	                    N-    N or fewer
	                    x     any length

	Examples:
		N 20-21 balanced
		S 10-13 6+,x,x,x                 (6+ spades)
		N 8-11 5,5,x,x / 5,x,5,x         (5-5 majors, or 5 spades & 5 diamonds)
		E 12-14 4,3,3,3 / 4,4,3,2

	Pure (no I/O): problems are reported as ok = false with a message, like the rest of the parser.
	The shape part is filtered against every possible s-h-d-c composition, and the surviving shapes
	(plus the hcp window) are handed to `norn.smartstack_make`.
*/

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../norn"

// An inclusive integer range; `lo`/`hi` bound either an hcp window or one suit's length.
@(private = "file")
Int_Range :: struct {
	lo: int,
	hi: int,
}

// One shape alternative: a keyword class, or a four-suit length pattern (S,H,D,C ranges).
@(private = "file")
Shape_Keyword :: enum {
	None,
	Any,
	Balanced,
	Semibalanced,
}

@(private = "file")
Alternative :: struct {
	keyword: Shape_Keyword, // .None means `pattern` is used instead
	pattern: [norn.SUIT_COUNT]Int_Range,
}

// Parse an `N` / `N+` / `N-` / `lo-hi` field into an inclusive range clamped to [0, max]. Used for
// both the hcp window (max 40) and per-suit lengths (max 13). Returns ok = false with a message on a
// non-integer or an empty field.
@(private = "file")
parse_range :: proc(text: string, max: int, what: string) -> (r: Int_Range, ok: bool, message: string) {
	if len(text) == 0 {
		return {}, false, fmt.tprintf("smartstack: empty %s", what)
	}
	if strings.equal_fold(text, "x") {
		return Int_Range{0, max}, true, ""
	}
	last := text[len(text) - 1]
	if last == '+' {
		n, parsed := strconv.parse_int(text[:len(text) - 1])
		if !parsed {
			return {}, false, fmt.tprintf("smartstack: %s %q is not a number", what, text)
		}
		return Int_Range{clamp(n, 0, max), max}, true, ""
	}
	if last == '-' {
		n, parsed := strconv.parse_int(text[:len(text) - 1])
		if !parsed {
			return {}, false, fmt.tprintf("smartstack: %s %q is not a number", what, text)
		}
		return Int_Range{0, clamp(n, 0, max)}, true, ""
	}
	if dash := strings.index_byte(text, '-'); dash > 0 {
		lo, lo_ok := strconv.parse_int(text[:dash])
		hi, hi_ok := strconv.parse_int(text[dash + 1:])
		if !lo_ok || !hi_ok {
			return {}, false, fmt.tprintf("smartstack: %s %q is not a range", what, text)
		}
		return Int_Range{clamp(lo, 0, max), clamp(hi, 0, max)}, true, ""
	}
	n, parsed := strconv.parse_int(text)
	if !parsed {
		return {}, false, fmt.tprintf("smartstack: %s %q is not a number", what, text)
	}
	return Int_Range{clamp(n, 0, max), clamp(n, 0, max)}, true, ""
}

// Parse one shape alternative: a keyword, or four comma-separated suit-length fields.
@(private = "file")
parse_alternative :: proc(text: string) -> (alt: Alternative, ok: bool, message: string) {
	switch {
	case strings.equal_fold(text, "any"):
		return Alternative{keyword = .Any}, true, ""
	case strings.equal_fold(text, "balanced"), strings.equal_fold(text, "bal"):
		return Alternative{keyword = .Balanced}, true, ""
	case strings.equal_fold(text, "semibalanced"), strings.equal_fold(text, "semi"):
		return Alternative{keyword = .Semibalanced}, true, ""
	}

	fields := strings.split(text, ",")
	defer delete(fields)
	if len(fields) != norn.SUIT_COUNT {
		return {}, false, fmt.tprintf("smartstack: shape %q needs %d comma-separated suit lengths (S,H,D,C) or a keyword", text, norn.SUIT_COUNT)
	}
	for f, i in fields {
		r, r_ok, why := parse_range(strings.trim_space(f), norn.HAND_SIZE, "suit length")
		if !r_ok {
			return {}, false, why
		}
		alt.pattern[i] = r
	}
	alt.keyword = .None
	return alt, true, ""
}

// Does an s-h-d-c length tuple satisfy this alternative?
@(private = "file")
shape_matches :: proc(shape: [norn.SUIT_COUNT]int, alt: Alternative) -> bool {
	switch alt.keyword {
	case .Any:
		return true
	case .Balanced:
		// deal's rule: no 5-card major, sum of squared lengths <= 47 (4333/4432/minor-5332).
		s, h, d, c := shape[0], shape[1], shape[2], shape[3]
		if s >= 5 || h >= 5 {
			return false
		}
		return s * s + h * h + d * d + c * c <= 47
	case .Semibalanced:
		// deal's rule: every suit a doubleton+, majors <= 5, minors <= 6.
		s, h, d, c := shape[0], shape[1], shape[2], shape[3]
		return s >= 2 && h >= 2 && d >= 2 && c >= 2 && s <= 5 && h <= 5 && d <= 6 && c <= 6
	case .None:
		for r, i in alt.pattern {
			if shape[i] < r.lo || shape[i] > r.hi {
				return false
			}
		}
		return true
	}
	return false
}

// Parse a full --smartstack spec into a built `norn.Smart_Stack`. Returns ok = false with a message
// on a malformed spec, an unknown seat, or a constraint that admits no hand at all.
parse_smartstack :: proc(spec: string) -> (ss: norn.Smart_Stack, ok: bool, message: string) {
	parts := strings.fields(spec)
	defer delete(parts)
	if len(parts) < 3 {
		return {}, false, "smartstack: expected 'SEAT HCP SHAPE', e.g. \"N 20-21 balanced\""
	}

	seat, seat_ok := parse_seat(parts[0])
	if !seat_ok {
		return {}, false, fmt.tprintf("smartstack: unknown seat %q (expected N, E, S or W)", parts[0])
	}

	hcp, hcp_ok, hcp_why := parse_range(parts[1], 40, "hcp")
	if !hcp_ok {
		return {}, false, hcp_why
	}

	// The shape part is everything after the seat and hcp. `fields` already dropped all whitespace,
	// so joining with "" yields the spaceless shape text (e.g. "4,3,3,3/4,4,3,2") to split on '/'.
	shape_text := strings.join(parts[2:], "")
	defer delete(shape_text)
	alts := strings.split(shape_text, "/")
	defer delete(alts)

	alternatives: [dynamic]Alternative
	defer delete(alternatives)
	for raw in alts {
		token := strings.trim_space(raw)
		if token == "" {
			continue
		}
		alt, alt_ok, why := parse_alternative(token)
		if !alt_ok {
			return {}, false, why
		}
		append(&alternatives, alt)
	}
	if len(alternatives) == 0 {
		return {}, false, "smartstack: no shape given"
	}

	// Keep every composition matching any alternative, then build the spec.
	all, count := norn.enumerate_shapes()
	chosen: [norn.MAX_SHAPES][norn.SUIT_COUNT]int
	chosen_count := 0
	for i in 0 ..< count {
		for alt in alternatives {
			if shape_matches(all[i], alt) {
				chosen[chosen_count] = all[i]
				chosen_count += 1
				break
			}
		}
	}

	built, build_ok := norn.smartstack_make(seat, chosen[:chosen_count], hcp.lo, hcp.hi)
	if !build_ok {
		return {}, false, fmt.tprintf("smartstack: no hand matches that shape and %d-%d hcp", hcp.lo, hcp.hi)
	}
	return built, true, ""
}
