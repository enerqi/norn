package norn

import "core:strconv"
import "core:strings"

/*
	auction.odin — the auction and the commentary a record carries, as written.

	`contract.odin` works an auction down to the one thing a player of the cards needs, the contract. This file keeps
	the auction itself - every call in order, which were alerted and what the record says they meant - and the
	record's COMMENTARY: the prose a vugraph commentator or a column writer attached to the board, each piece placed
	where it was written (before the auction, after a call, after a card of the play).

	LIN: `mb|<call>|` is a call (a trailing `!` alerts it), `an|<text>|` explains the call before it, `nt|<text>|` is
	a comment, and `pc|` counts the cards played so far. PBN: the `[Auction "<dealer>"]` section's calls (`Pass`,
	`X`, `XX`, `1S`, `AP` for the passes that end it, `=n=` a reference to its `[Note "n:<text>"]`), and `{...}` or
	`;` to the end of a line anywhere in the board.

	Both are FIXED-SIZE values on `Board` (`AUCTION_CAP` calls, `COMMENT_CAP` comments), so a board is still a
	plain value nobody frees; the strings alias the record's text, as `Board_Table`'s do. A record with more says
	so (`Auction.cut`, `Commentary.dropped`) rather than growing.

	Comment text is kept as written: a renderer decides what `!s` / `\S` and line breaks mean.
*/

AUCTION_CAP :: 64
COMMENT_CAP :: 32

Call_Kind :: enum u8 {
	Pass,
	Double,
	Redouble,
	Bid,
}

// One call of a recorded auction. `level` and `strain` are a bid's; `alerted` is the record marking it (LIN `!`, or
// an explanation given), `explanation` what the record says it meant (LIN `an|`, a PBN note), "" when it says
// nothing.
Call :: struct {
	kind:        Call_Kind,
	level:       int,
	strain:      Contract_Strain,
	alerted:     bool,
	explanation: string,
}

// The calls in the order made, the first by `dealer`. `cut` is set when the record had a call that did not read, or
// more than `AUCTION_CAP`: the calls stop before it, so the seat of every call kept is still right.
Auction :: struct {
	dealer: Seat,
	calls:  [AUCTION_CAP]Call,
	count:  int,
	cut:    bool,
}

// A piece of the record's commentary, and where it stands: after `calls` calls of the auction (0 = before it) and
// `cards` cards of the play (0 = before the lead). A comment after the play has every call and every card before it.
Comment :: struct {
	text:  string,
	calls: int,
	cards: int,
}

// A board's comments in the order written; `dropped` counts those past `COMMENT_CAP`.
Commentary :: struct {
	comments: [COMMENT_CAP]Comment,
	count:    int,
	dropped:  int,
}

// The calls an auction holds.
auction_calls :: proc(auction: ^Auction) -> []Call {
	return auction.calls[:auction.count]
}

// The comments a board's commentary holds.
commentary_comments :: proc(commentary: ^Commentary) -> []Comment {
	return commentary.comments[:commentary.count]
}

// The seat that made call `index` of the auction.
call_seat :: proc "contextless" (auction: Auction, index: int) -> Seat {
	return Seat((int(auction.dealer) + index) % SEAT_COUNT)
}

/*
The contract an auction reaches (see `derive_contract`: the declarer is the first of the winning side to name the
final strain). ok=false for an auction with no bid.
*/
auction_contract :: proc(auction: Auction) -> (contract: Contract, ok: bool) {
	first_namer: [2][Contract_Strain]Maybe(Seat)
	last := -1
	doubling := Doubling.None
	for i in 0 ..< auction.count {
		call := auction.calls[i]
		switch call.kind {
		case .Pass:
		case .Double:
			doubling = .Doubled
		case .Redouble:
			doubling = .Redoubled
		case .Bid:
			doubling = .None
			seat := call_seat(auction, i)
			side := int(seat) % 2
			if first_namer[side][call.strain] == nil {
				first_namer[side][call.strain] = seat
			}
			last = i
		}
	}
	if last < 0 {
		return {}, false
	}
	bid := auction.calls[last]
	side := int(call_seat(auction, last)) % 2
	declarer, _ := first_namer[side][bid.strain].?
	return {level = bid.level, strain = bid.strain, declarer = declarer, doubling = doubling}, true
}

// Read one call as LIN or PBN writes it (`p` / `Pass`, `d` / `x` / `X`, `r` / `xx` / `XX`, `1S` / `3N` / `3NT`). A
// trailing `!` alerts it; a `?` (a PBN commentator's mark) is dropped.
@(private)
read_call :: proc(token: string) -> (call: Call, ok: bool) {
	t := strings.trim_space(token)
	for len(t) > 0 && (t[len(t) - 1] == '!' || t[len(t) - 1] == '?') {
		if t[len(t) - 1] == '!' {
			call.alerted = true
		}
		t = t[:len(t) - 1]
	}
	if len(t) == 0 {
		return {}, false
	}
	lower := strings.to_lower(t, context.temp_allocator)
	switch lower {
	case "p", "pass":
		call.kind = .Pass
		return call, true
	case "d", "x", "dbl":
		call.kind = .Double
		return call, true
	case "r", "xx", "rdbl":
		call.kind = .Redouble
		return call, true
	}
	if t[0] < '1' || t[0] > '7' {
		return {}, false
	}
	strain, sok := contract_strain_from_token(t[1:])
	if !sok {
		return {}, false
	}
	call.kind, call.level, call.strain = .Bid, int(t[0] - '0'), strain
	return call, true
}

@(private = "file")
add_call :: proc(auction: ^Auction, call: Call, ok: bool) {
	if auction.cut {
		return
	}
	if !ok || auction.count == AUCTION_CAP {
		auction.cut = true
		return
	}
	auction.calls[auction.count] = call
	auction.count += 1
}

@(private = "file")
add_comment :: proc(commentary: ^Commentary, text: string, calls, cards: int) {
	t := strings.trim_space(text)
	if t == "" {
		return
	}
	if commentary.count == COMMENT_CAP {
		commentary.dropped += 1
		return
	}
	commentary.comments[commentary.count] = {t, calls, cards}
	commentary.count += 1
}

/*
The auction and the commentary of a LIN record: each `mb|` call in order (from `dealer`, the `md|` digit's seat),
an `an|` explaining the call before it, and each `nt|` comment placed after the calls and `pc|` cards before it.
The auction is nil when the record has no `mb|`.
*/
@(private)
lin_auction :: proc(text: string, dealer: Seat) -> (auction: Maybe(Auction), commentary: Commentary) {
	a := Auction {
		dealer = dealer,
	}
	has := false
	cards := 0
	pos := 0
	for tok in lin_next_token(text, &pos) {
		switch tok.key {
		case "mb":
			has = true
			call, ok := read_call(tok.value)
			add_call(&a, call, ok)
		case "an":
			if a.count > 0 && !a.cut {
				a.calls[a.count - 1].explanation = strings.trim_space(tok.value)
				a.calls[a.count - 1].alerted = true
			}
		case "pc":
			cards += 1
		case "nt":
			add_comment(&commentary, tok.value, a.count, cards)
		}
	}
	if has {
		auction = a
	}
	return auction, commentary
}

/*
The auction and the commentary of a PBN board. The `[Auction "<dealer>"]` section's calls, `AP` standing for the
passes that end the auction and `=n=` for the call's explanation in `[Note "n:<text>"]` (the notes after the
section); `{...}` and `;` comments anywhere in the board, each placed after the calls read and the play section's
cards written before it (the play section's cards count in its own order, a row a trick, so a comment between
rows stands after that many tricks). `%` lines (a file's export header) are skipped. The auction is nil when the
board has no `[Auction]` section.
*/
@(private)
pbn_auction :: proc(text: string) -> (auction: Maybe(Auction), commentary: Commentary) {
	Section :: enum {
		None,
		Auction,
		Play,
	}
	a: Auction
	has := false
	section := Section.None
	notes_for_auction := false
	refs: [AUCTION_CAP]int // the note each call refers to, 0 for none
	notes: [AUCTION_CAP + 1]string // an auction note's text, by number
	cards := 0
	line_start := true
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == '\n':
			line_start = true
			i += 1
			continue
		case c == ' ' || c == '\t' || c == '\r':
			i += 1
			continue
		case c == '%' && line_start:
			eol := strings.index_byte(text[i:], '\n')
			i = eol < 0 ? len(text) : i + eol
			continue
		}
		line_start = false
		switch {
		case c == '{':
			close := strings.index_byte(text[i:], '}')
			end := close < 0 ? len(text) : i + close
			add_comment(&commentary, text[i + 1:end], a.count, cards)
			i = close < 0 ? len(text) : end + 1
		case c == ';':
			eol := strings.index_byte(text[i:], '\n')
			end := eol < 0 ? len(text) : i + eol
			add_comment(&commentary, text[i + 1:end], a.count, cards)
			i = end
		case c == '[':
			close := strings.index_byte(text[i:], ']')
			end := close < 0 ? len(text) : i + close
			tag := text[i + 1:end]
			i = close < 0 ? len(text) : end + 1
			name := tag
			value := ""
			if sp := strings.index_byte(tag, ' '); sp >= 0 {
				name = tag[:sp]
				value = strings.trim(tag[sp + 1:], " \"")
			}
			switch name {
			case "Auction":
				section, has, notes_for_auction = .Auction, true, true
				if len(value) > 0 {
					a.dealer, _ = seat_from_letter(value[0])
				}
			case "Play":
				section, notes_for_auction = .Play, false
			case "Note":
				section = .None
				if notes_for_auction {
					if colon := strings.index_byte(value, ':'); colon > 0 {
						if n, ok := strconv.parse_int(value[:colon], 10); ok && n > 0 && n < len(notes) {
							notes[n] = strings.trim_space(value[colon + 1:])
						}
					}
				}
			case:
				section, notes_for_auction = .None, false
			}
		case:
			end := i
			for end < len(text) && !strings.contains_rune(" \t\r\n{;[", rune(text[end])) {
				end += 1
			}
			token := text[i:end]
			i = end
			if token == "*" {
				section = .None
				continue
			}
			#partial switch section {
			case .Auction:
				switch {
				case token[0] == '$' || token == "-":
				// a NAG, a call not made
				case token[0] == '=':
					n, ok := strconv.parse_int(strings.trim(token, "="), 10)
					if ok && a.count > 0 && !a.cut {
						refs[a.count - 1] = n
					}
				case token == "AP" || token == "ap":
					// The passes that end it: three after a bid, four when nobody bid.
					passes := 4
					for k in 0 ..< a.count {
						if a.calls[k].kind == .Bid {
							passes = 3
						}
					}
					for _ in 0 ..< passes {
						add_call(&a, {kind = .Pass}, true)
					}
				case:
					call, ok := read_call(token)
					add_call(&a, call, ok)
				}
			case .Play:
				if token[0] != '$' && token[0] != '=' && token[0] != '^' {
					cards += 1
				}
			}
		}
	}
	for i in 0 ..< a.count {
		if n := refs[i]; n > 0 && n < len(notes) && notes[n] != "" {
			a.calls[i].explanation = notes[n]
			a.calls[i].alerted = true
		}
	}
	if has {
		auction = a
	}
	return auction, commentary
}
