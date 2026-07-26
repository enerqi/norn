package norn

import "core:strings"

/*
	contract.odin — deriving the played contract (denomination, level, declarer) from a source record.

	The deal readers (pbn.odin, lin.odin) parse the four hands; this file is the shared machinery for the
	OTHER thing a record often carries: which contract was actually reached. A LIN record carries an
	`mb|` auction, a full PBN record carries `[Contract]` / `[Declarer]` tags. Both feed the same three
	fields on `Parsed_Board` (contract_level / contract_strain / declarer, gated by has_contract), so
	downstream code can default its analysis to the contract that happened at the table rather than
	guessing one.

	The LIN path needs to work an auction back to a declarer: bridge's rule is that the declarer is the
	FIRST player of the contracting side to have named the final denomination — not merely whoever made
	the last bid. `derive_contract` implements that from the dealer + the ordered call list.
*/

// A contract's denomination: the four suits or notrump. Distinct from `Suit` because notrump is not a
// suit; the four suit variants keep the `Suit` names and `NoTrump` is the fifth.
Contract_Strain :: enum {
	Clubs,
	Diamonds,
	Hearts,
	Spades,
	NoTrump,
}

// Parse a contract denomination token: notrump (`NT` or a lone `N`, either case) or a single suit letter
// S/H/D/C (either case). ok=false on anything else. Contextless so the deal readers can call it freely.
contract_strain_from_token :: proc "contextless" (tok: string) -> (strain: Contract_Strain, ok: bool) {
	if len(tok) == 2 && (tok[0] == 'N' || tok[0] == 'n') && (tok[1] == 'T' || tok[1] == 't') {
		return .NoTrump, true
	}
	if len(tok) != 1 {
		return .NoTrump, false
	}
	switch tok[0] {
	case 'N', 'n':
		return .NoTrump, true
	case 'S', 's':
		return .Spades, true
	case 'H', 'h':
		return .Hearts, true
	case 'D', 'd':
		return .Diamonds, true
	case 'C', 'c':
		return .Clubs, true
	}
	return .NoTrump, false
}

// The kind of one auction call.
@(private)
Auction_Call_Kind :: enum {
	Unknown, // an unparseable/junk token (still consumes a turn)
	Bid, // a level + denomination bid, e.g. 1S / 2N / 3NT
	Pass,
	Double,
	Redouble,
}

// One parsed auction call. `level`/`strain` are meaningful only when kind == .Bid.
@(private)
Auction_Call :: struct {
	kind:   Auction_Call_Kind,
	level:  int,
	strain: Contract_Strain,
}

// Parse a single auction call token (LIN `mb|` value form): a pass (`p`), double (`d`/`x`), redouble
// (`r`), or a level+denomination bid (`1S`, `2N`, `3NT`). A trailing `!` alert marker is stripped. A
// token starting with a letter is never a bid (bids lead with a digit 1..7), so `d`/`x` are unambiguously
// double. Anything unrecognised -> .Unknown (still a turn taken, so seat rotation stays aligned).
@(private)
parse_auction_call :: proc(tok: string) -> Auction_Call {
	t := strings.trim_space(tok)
	for len(t) > 0 && t[len(t) - 1] == '!' {
		t = t[:len(t) - 1]
	}
	if len(t) == 0 {
		return {kind = .Unknown}
	}
	switch t[0] {
	case 'p', 'P':
		return {kind = .Pass}
	case 'd', 'D', 'x', 'X':
		return {kind = .Double}
	case 'r', 'R':
		return {kind = .Redouble}
	}
	if t[0] < '1' || t[0] > '7' {
		return {kind = .Unknown}
	}
	strain, ok := contract_strain_from_token(t[1:])
	if !ok {
		return {kind = .Unknown}
	}
	return {kind = .Bid, level = int(t[0] - '0'), strain = strain}
}

// Derive the final contract from an auction. `calls` are the call tokens in the order made, starting from
// `dealer` and going clockwise (Seat's backing order N E S W already IS clockwise, so call i belongs to
// the seat i steps from the dealer). The returned `declarer` is the FIRST player of the contracting side
// to have named the final denomination — bridge's standard rule — not merely the last bidder. `ok` is
// false when the auction holds no actual bid (empty, or passed out), i.e. there is no contract.
derive_contract :: proc(
	dealer: Seat,
	calls: []string,
) -> (
	level: int,
	strain: Contract_Strain,
	declarer: Seat,
	ok: bool,
) {
	// first_namer[side][strain]: the first seat of that side to bid that denomination; -1 = none yet.
	// side is Seat-index parity — N=0,S=2 (even) are N/S side 0; E=1,W=3 (odd) are E/W side 1.
	first_namer: [2][Contract_Strain]int
	for &row in first_namer {
		for &v in row {
			v = -1
		}
	}

	last_level := 0
	last_strain := Contract_Strain.NoTrump
	last_side := -1

	for tok, i in calls {
		call := parse_auction_call(tok)
		if call.kind != .Bid {
			continue // passes, doubles, redoubles and junk do not change the denomination
		}
		seat := Seat((int(dealer) + i) % SEAT_COUNT)
		side := int(seat) % 2
		if first_namer[side][call.strain] < 0 {
			first_namer[side][call.strain] = int(seat)
		}
		last_level, last_strain, last_side = call.level, call.strain, side
	}
	if last_side < 0 {
		return 0, .NoTrump, dealer, false
	}
	return last_level, last_strain, Seat(first_namer[last_side][last_strain]), true
}
