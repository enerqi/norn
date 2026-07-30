package combo

/*
	book — the pluggable "published suit-combination table" seam.

	combo computes its OWN recommendation for every holding (see combo.odin). Separately, published
	suit-combination tables ("the book") give the expert line + its percentages against best defence for
	the holdings they cover, and on some of those our fixed line underperforms published theory. Where a
	book covers the live holding we OVERRIDE our recommendation with the book's (see `book_override`).

	The table itself is NOT part of combo. Any such corpus is somebody else's editorial work — its prose
	and arrangement belong to whoever compiled it, and a library should not carry that. So combo owns
	only the MECHANISM and the consuming program supplies the DATA:

	    combo.set_suit_book(combo.Suit_Book{lookup = my_lookup, shutdown = my_shutdown})

	With no book registered every lookup misses and combo reports its own engine line — the whole
	feature degrades to "engine only", which is the correct default for a library.

	What combo keeps here, because both sides need it and both are engine facts rather than book facts:

	- `book_key` — the equivalence key. Two holdings share a key iff our single-dummy engine treats them
	  identically (it serialises `sd_best_joint_table`). A provider indexes its entries by this so a
	  live holding finds an entry describing the same combination, low spots and orientation aside.
	- `book_line_applies` — the card-validity gate. Engine equivalence is ODDS equivalence, so it merges
	  holdings with different honours (AQ9x/T8x missing KJ and AKJ9/xxx missing QT are both a double
	  finesse: same odds, same key). Percentages transfer between those; the LINE TEXT does not, since
	  it names specific cards ("low to the K" on a holding with no king). A provider must gate a key hit
	  on this, or it will show a line the holding cannot play.
*/

import "core:strings"

// One trick target from a book entry: `pct` = the book's chance of taking at least `need` tricks against best
// defence, `line` = the play that gets there (empty when it is the entry's headline line).
Book_Target :: struct {
	need, pct: int,
	line:      string,
}

// One holding's published entry: the raw holding it describes (`n`, `s` as `norn.Hand_Summary.suits[suit]`
// masks), a representative line label, and up to 6 cumulative trick targets.
Book_Entry :: struct {
	n, s:    u16,
	line:    string,
	nt:      int,
	targets: [6]Book_Target,
}

// Resolve an NS single-suit holding to its published entry. `false` = not covered (combo then keeps its own
// line). Implementations must gate hits with `book_line_applies` — see the header.
Book_Lookup_Proc :: proc(n, s: u16) -> (Book_Entry, bool)

// Optional teardown for whatever the provider built lazily (its key index, typically). `combo.shutdown` calls
// it so a leak-checked build reports clean.
Book_Shutdown_Proc :: proc()

// A registered published-table provider. Both fields may be nil: a nil `lookup` means "no book" (every
// holding falls back to the engine line).
Suit_Book :: struct {
	lookup:   Book_Lookup_Proc,
	shutdown: Book_Shutdown_Proc,
}

@(private)
g_book: Suit_Book

// Register the published suit-combination table combo should prefer over its own line where it has an entry.
// Call once at program start, before any annotate. Passing `{}` unregisters (back to engine-only).
set_suit_book :: proc(book: Suit_Book) {
	g_book = book
}

// True when a published table is registered, i.e. when book overrides can happen at all.
suit_book_registered :: proc() -> bool {
	return g_book.lookup != nil
}

// Release the registered provider's own allocations. Called by `shutdown`; harmless with no provider.
@(private)
book_shutdown :: proc() {
	if g_book.shutdown != nil {
		g_book.shutdown()
	}
}

// The engine equivalence key for a holding: the recommended line's joint (east_len x tricks) count table,
// serialised. Deterministic and identical whether called on a book entry's holding or a live one, so
// equal-behaviour holdings map together. Allocated in `allocator` (temp for lookups; the persistent heap when
// interned as a provider's map key).
book_key :: proc(n, s: u16, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, card_count(n | s))
	strings.write_byte(&b, ':')
	tbl := sd_best_joint_table(n, s)
	for a in 0 ..= tbl.m {
		for k in 0 ..= RANKS {
			c := tbl.count[a][k]
			if c > 0.5 {
				strings.write_int(&b, a)
				strings.write_byte(&b, '-')
				strings.write_int(&b, k)
				strings.write_byte(&b, '=')
				strings.write_int(&b, int(c + 0.5))
				strings.write_byte(&b, ',')
			}
		}
	}
	return strings.to_string(b)
}

// Honours whose identity a line's text depends on (Ten..Ace).
@(private)
BOOK_HONOURS :: u16(0x1F00)

// True when an entry for holding (`en`, `es`) describes the SAME suit combination as the live (`n`, `s`) up to
// interchangeable low spots: each side holds the same honours (Ten+) and the same number of cards, in either
// hand assignment (the key is orientation-symmetric, so an entry may be stored mirrored). This is what makes
// the entry's card-named line literally valid for the live holding.
book_line_applies :: proc(n, s, en, es: u16) -> bool {
	direct :=
		n & BOOK_HONOURS == en & BOOK_HONOURS &&
		s & BOOK_HONOURS == es & BOOK_HONOURS &&
		card_count(n) == card_count(en) &&
		card_count(s) == card_count(es)
	swap :=
		n & BOOK_HONOURS == es & BOOK_HONOURS &&
		s & BOOK_HONOURS == en & BOOK_HONOURS &&
		card_count(n) == card_count(es) &&
		card_count(s) == card_count(en)
	return direct || swap
}
