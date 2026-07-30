package norn

import "core:strings"

/*
	contract.odin — deriving the played contract (denomination, level, declarer) from a source record.

	The deal readers (pbn.odin, lin.odin) parse the four hands; this file is the shared machinery for the
	OTHER thing a record often carries: which contract was actually reached. A LIN record carries an
	`mb|` auction, a full PBN record carries `[Contract]` / `[Declarer]` tags. Both feed the same
	`Contract` value on `Board` (as a `Maybe(Contract)` — a record need not name one), so
	downstream code can default its analysis to the contract that happened at the table rather than
	guessing one.

	The LIN path needs to work an auction back to a declarer: bridge's rule is that the declarer is the
	FIRST player of the contracting side to have named the final denomination — not merely whoever made
	the last bid. `derive_contract` implements that from the dealer + the ordered call list.
*/

// A contract's denomination: the four suits or notrumps. Distinct from `Suit` because notrumps is not a
// suit; the four suit variants keep the `Suit` names and `NoTrumps` is the fifth.
Contract_Strain :: enum {
	Clubs,
	Diamonds,
	Hearts,
	Spades,
	NoTrumps,
}

// A contract reached at the table: its level and denomination, plus the seat that plays it. The three are
// meaningful only together — a record either names a contract or it does not — so they travel as one
// value, held as `Maybe(Contract)` by `Board` rather than as loose fields behind a bool flag.
// `declarer` is the seat that FIRST named the final denomination for its side (bridge's rule), not merely
// whoever made the last bid.
Contract :: struct {
	level:    int, // 1..7
	strain:   Contract_Strain,
	declarer: Seat,
}

// Parse a contract denomination token: notrumps (`NT` or a lone `N`, either case) or a single suit letter
// S/H/D/C (either case). ok=false on anything else. Contextless so the deal readers can call it freely.
contract_strain_from_token :: proc "contextless" (tok: string) -> (strain: Contract_Strain, ok: bool) {
	if len(tok) == 2 && (tok[0] == 'N' || tok[0] == 'n') && (tok[1] == 'T' || tok[1] == 't') {
		return .NoTrumps, true
	}
	if len(tok) != 1 {
		return .NoTrumps, false
	}
	switch tok[0] {
	case 'N', 'n':
		return .NoTrumps, true
	case 'S', 's':
		return .Spades, true
	case 'H', 'h':
		return .Hearts, true
	case 'D', 'd':
		return .Diamonds, true
	case 'C', 'c':
		return .Clubs, true
	}
	return .NoTrumps, false
}

// A level + denomination bid, e.g. 1S / 2N / 3NT — the only call that names a contract, and so the only
// one carrying a payload.
@(private)
Auction_Bid :: struct {
	level:  int,
	strain: Contract_Strain,
}

@(private)
Auction_Pass :: struct {}
@(private)
Auction_Double :: struct {}
@(private)
Auction_Redouble :: struct {}

// One parsed auction call: a bid (with its level + denomination) or one of the three payload-free calls.
// A nil call is an unparseable/junk token — still a turn taken, so seat rotation stays aligned.
@(private)
Auction_Call :: union {
	Auction_Bid,
	Auction_Pass,
	Auction_Double,
	Auction_Redouble,
}

// Parse a single auction call token (LIN `mb|` value form): a pass (`p`), double (`d`/`x`), redouble
// (`r`), or a level+denomination bid (`1S`, `2N`, `3NT`). A trailing `!` alert marker is stripped. A
// token starting with a letter is never a bid (bids lead with a digit 1..7), so `d`/`x` are unambiguously
// double. Anything unrecognised -> nil (still a turn taken, so seat rotation stays aligned).
@(private)
parse_auction_call :: proc(tok: string) -> Auction_Call {
	t := strings.trim_space(tok)
	for len(t) > 0 && t[len(t) - 1] == '!' {
		t = t[:len(t) - 1]
	}
	if len(t) == 0 {
		return nil
	}
	switch t[0] {
	case 'p', 'P':
		return Auction_Pass{}
	case 'd', 'D', 'x', 'X':
		return Auction_Double{}
	case 'r', 'R':
		return Auction_Redouble{}
	}
	if t[0] < '1' || t[0] > '7' {
		return nil
	}
	strain, ok := contract_strain_from_token(t[1:])
	if !ok {
		return nil
	}
	return Auction_Bid{level = int(t[0] - '0'), strain = strain}
}

// Derive the final contract from an auction. `calls` are the call tokens in the order made, starting from
// `dealer` and going clockwise (Seat's backing order N E S W already IS clockwise, so call i belongs to
// the seat i steps from the dealer). The returned contract's `declarer` is the FIRST player of the
// contracting side to have named the final denomination — bridge's standard rule — not merely the last
// bidder. `ok` is false when the auction holds no actual bid (empty, or passed out), i.e. no contract.
derive_contract :: proc(dealer: Seat, calls: []string) -> (contract: Contract, ok: bool) {
	// first_namer[side][strain]: the first seat of that side to bid that denomination, nil until one has.
	// side is Seat-index parity — N=0,S=2 (even) are N/S side 0; E=1,W=3 (odd) are E/W side 1.
	first_namer: [2][Contract_Strain]Maybe(Seat)

	last_level := 0
	last_strain := Contract_Strain.NoTrumps
	last_side := -1

	for tok, i in calls {
		// Passes, doubles, redoubles and junk do not change the denomination — only a bid does.
		bid, is_bid := parse_auction_call(tok).(Auction_Bid)
		if !is_bid {
			continue
		}
		seat := Seat((int(dealer) + i) % SEAT_COUNT)
		side := int(seat) % 2
		if first_namer[side][bid.strain] == nil {
			first_namer[side][bid.strain] = seat
		}
		last_level, last_strain, last_side = bid.level, bid.strain, side
	}
	if last_side < 0 {
		return {}, false
	}
	// The winning side bid the final denomination at least once, so its first namer is necessarily set.
	declarer, named := first_namer[last_side][last_strain].?
	assert(named, "derive_contract: a side won the auction in a denomination it never named")
	return {level = last_level, strain = last_strain, declarer = declarer}, true
}
