package combo

/*
	single_dummy_narrate.odin — Phase 4 of the suit solver: a certified line (`sd_certified_line`) in words.

	Two strings, as the published-book override has (`book_override`): a SHORT LABEL in the book's style
	("Play A then low to Q", for the line cell) and a TOOLTIP that says the line trick by trick - what to do
	when the second hand plays something else, which fourth-hand cards change the next lead - and the chances
	against the best defence.

	The line is a tree (`Sd_Policy`), so the words follow its MAIN PATH: at each defender turn the defender
	plays low (the case a book line describes), or shows out when that is all it can do; the other cards are
	said as alternatives. Declarer's cards are named from the real holding, through the policy's rank map (a
	relabelled line was searched with other small cards): the nine and up by rank, the rest `low`. A
	defender's card is named by the interval it came from: `low` for the lowest interval of spot cards at that
	turn, every card by rank for the others.

	The words stop once the rest of the main path is fixed - the same plays whatever the defenders show, each
	lead a winner or a card given up (`narr_fixed_tail`). No apostrophes or double quotes: the strings are
	emitted inside a single-quoted HTML attribute, as JSON.
*/

import "core:fmt"
import "core:mem"
import "core:strings"

// The most tricks the label names; the tooltip goes on further.
@(private)
LABEL_TRICKS :: 3
@(private)
TIP_TRICKS :: 6

@(private)
Narrator :: struct {
	pol:   ^Sd_Policy,
	inv:   [RANKS]int, // policy rank -> real rank
	alloc: mem.Allocator,
	class_below: int, // narrating a CLASS of holdings: its small cards are those below this rank (0: not)
}

@(private)
SEAT_NAMES := [4]string{"North", "East", "South", "West"}

/*
The certified line `c` for the real holding `north`/`south`, as a short label and a tooltip. False for a
`.Fixed` line - the engine's own narration (`describe_suit_line`) already says those.

`class_below` narrates the line for every holding that differs from this one only in its cards below that
rank (the table of `suit_solver_table.odin`, whose holding is the class's worst): no defender card below it is
named, the chances are a floor ("at least"), and nothing is claimed optimal.
*/
sd_narrate :: proc(
	c: ^Sd_Certified,
	north, south: u16,
	class_below := 0,
	allocator := context.temp_allocator,
) -> (
	label, tip: string,
	ok: bool,
) {
	if c.policy == nil || c.policy.root == nil || !c.policy.root.decided {
		return
	}
	nr := Narrator {
		pol   = c.policy,
		alloc = allocator,
		class_below = class_below,
	}
	for r in 0 ..< RANKS {
		nr.inv[c.perm[r]] = r
	}

	items := make([dynamic]string, 0, LABEL_TRICKS, allocator)
	tb := strings.builder_make(allocator)
	node := c.policy.root
	tricks := 0
	for ; node != nil && node.decided && tricks < TIP_TRICKS; tricks += 1 {
		if tail := narr_fixed_tail(&nr, node); tail != .Adaptive {
			if tricks == 0 && tail == .Cash {
				append(&items, "cash from the top")
				strings.write_string(&tb, "Cash your winners from the top.")
				tricks = 1
				node = nil
				break
			}
			if tricks > 0 {
				strings.write_string(&tb, " Then cash your winners." if tail == .Cash else " Then play the rest out.")
				node = nil
				break
			}
		}
		if tricks < LABEL_TRICKS {
			append(&items, narr_label_trick(&nr, node))
		}
		if tricks > 0 {
			strings.write_byte(&tb, ' ')
		}
		node = narr_tip_trick(&nr, &tb, node, tricks)
	}

	// The same play on consecutive tricks is said once: `duck twice`.
	said := make([dynamic]string, 0, len(items), allocator)
	for i := 0; i < len(items); {
		j := i
		for j < len(items) && items[j] == items[i] {
			j += 1
		}
		switch j - i {
		case 1:
			append(&said, items[i])
		case 2:
			append(&said, fmt.aprintf("%s twice", items[i], allocator = allocator))
		case:
			append(&said, fmt.aprintf("%s %d times", items[i], j - i, allocator = allocator))
		}
		i = j
	}
	lb := strings.builder_make(allocator)
	for item, i in said {
		if i == 0 {
			if strings.has_prefix(item, "run ") {
				strings.write_string(&lb, "Run ")
				strings.write_string(&lb, item[len("run "):])
				continue
			}
			if strings.has_prefix(item, "cash ") || strings.has_prefix(item, "duck") {
				strings.write_byte(&lb, item[0] - 'a' + 'A')
				strings.write_string(&lb, item[1:])
				continue
			}
			strings.write_string(&lb, "Play ")
		} else {
			strings.write_string(&lb, " then ")
		}
		strings.write_string(&lb, item)
	}
	if tricks > LABEL_TRICKS && node != nil {
		strings.write_string(&lb, " ...")
	}

	// The chances, as the book gives them: P(at least k tricks) against the best defence.
	strings.write_string(&tb, " Chances vs best defence, at least:" if class_below > 0 else " Chances vs best defence:")
	first := true
	for k := c.dist.max_tricks; k >= 1; k -= 1 {
		at_least := f64(0)
		for j in k ..= RANKS {
			at_least += c.dist.p[j]
		}
		if at_least < 0.0005 {
			continue
		}
		if !first {
			strings.write_byte(&tb, ',')
		}
		first = false
		fmt.sbprintf(&tb, " %d trick%s %d%%", k, "" if k == 1 else "s", int(at_least * 100 + 0.5))
		if at_least >= 0.9995 {
			break
		}
	}
	strings.write_byte(&tb, '.')
	if c.optimal && class_below == 0 {
		strings.write_string(&tb, " No line does better.")
	}
	return strings.to_string(lb), strings.to_string(tb), true
}

// A declarer card in words: named from the nine up, `low` below.
@(private)
narr_card :: proc(nr: ^Narrator, policy_rank: int) -> string {
	r := nr.inv[policy_rank]
	return RANK_NAMES[r] if r >= 7 else "low"
}

// Does the declarer card beat every missing card still out? (Then leading it is cashing it.)
@(private)
narr_top :: proc(node: ^Policy_Node, policy_rank: int) -> bool {
	live: u16
	for w in node.worlds {
		live |= w.e | w.w
	}
	return live >> uint(policy_rank + 1) == 0
}

// The main path at a defender turn: the defender plays its lowest interval, or shows out when that is all
// it can do.
@(private)
narr_main_branch :: proc(node: ^Policy_Node) -> (g: int, child: ^Policy_Node) {
	for k := RANKS; k >= 0; k -= 1 {
		if node.branches[k] != nil {
			return k, node.branches[k]
		}
	}
	return POLICY_VOID, node.branches[POLICY_VOID]
}

// What the leader's partner plays after second-hand branch `t`, in words (`the Q from South`, `low from
// South`, or `` when that hand has none).
@(private)
narr_answer :: proc(nr: ^Narrator, t: ^Policy_Node, partner_seat: int) -> string {
	if !t.decided {
		return ""
	}
	card := narr_card(nr, t.rank)
	if card == "low" {
		return fmt.aprintf("low from %s", SEAT_NAMES[partner_seat], allocator = nr.alloc)
	}
	return fmt.aprintf("the %s from %s", card, SEAT_NAMES[partner_seat], allocator = nr.alloc)
}

// A trick's lead in words (`low from North`, `the J from North`).
@(private)
narr_lead :: proc(nr: ^Narrator, t: ^Policy_Node) -> string {
	card := narr_card(nr, t.rank)
	if card == "low" {
		return fmt.aprintf("low from %s", SEAT_NAMES[t.hand], allocator = nr.alloc)
	}
	return fmt.aprintf("the %s from %s", card, SEAT_NAMES[t.hand], allocator = nr.alloc)
}

/*
The cards a defender may show at `node` from the intervals in `groups`, as one phrase: `plays the K, J or
low`, `plays low, or shows out`, `shows out`.
*/
@(private)
narr_defender_cards :: proc(nr: ^Narrator, b: ^strings.Builder, node: ^Policy_Node, groups: [RANKS + 2]bool) {
	sep := node.n | node.s | node.played
	live: u16
	for w in node.worlds {
		live |= w.e | w.w
	}
	interval_cards :: proc(nr: ^Narrator, live, sep: u16, g: int) -> (cards: u16) {
		for r in 0 ..< RANKS {
			if live & rank_bit(r) != 0 && card_count(sep >> uint(r + 1)) == g {
				cards |= rank_bit(nr.inv[r])
			}
		}
		return
	}
	SPOTS :: u16(1) << 8 - 1 // the nine and below
	class_spots := u16(1) << uint(nr.class_below) - 1
	// `low` is one interval's word at a turn: the lowest of those holding only spot cards. Any other
	// interval's cards are named, or `plays low` would mean two things in one tooltip.
	low_g := -1
	for c, g in node.branches {
		if c != nil && g != POLICY_VOID && interval_cards(nr, live, sep, g) & ~SPOTS == 0 {
			low_g = g
		}
	}
	named: u16
	low, out := false, false
	for on, g in groups {
		if !on {
			continue
		}
		if g == POLICY_VOID {
			out = true
			continue
		}
		if g == low_g {
			low = true
			continue
		}
		cards := interval_cards(nr, live, sep, g)
		if cards & class_spots != 0 {
			low = true // a class's small spots are not the same cards in every member
			cards &~= class_spots
		}
		named |= cards
	}
	words := make([dynamic]string, 0, RANKS + 1, nr.alloc)
	for r := RANKS - 1; r >= 0; r -= 1 {
		if named & rank_bit(r) != 0 {
			append(&words, RANK_NAMES[r])
		}
	}
	if low {
		append(&words, "low")
	}
	if len(words) > 0 {
		strings.write_string(b, "plays ")
		if named != 0 {
			strings.write_string(b, "the ")
		}
		for w, i in words {
			if i > 0 {
				strings.write_string(b, " or " if i == len(words) - 1 else ", ")
			}
			strings.write_string(b, w)
		}
	}
	if out {
		switch len(words) {
		case 0:
			strings.write_string(b, "shows out")
		case 1:
			strings.write_string(b, " or shows out")
		case:
			strings.write_string(b, ", or shows out")
		}
	}
}

@(private)
Tail :: enum u8 {
	Adaptive, // some later play depends on what the defenders show
	Cash, // only winners are led from here
	Fixed, // the same plays whatever is shown, some of them cards given up
}

// Is the rest of the main path, from the lead `node`, fixed? Each trick's partner card and the next lead
// must be the same whatever the defenders show, and each lead a winner or a low card given up.
@(private)
narr_fixed_tail :: proc(nr: ^Narrator, node: ^Policy_Node) -> Tail {
	cash := true
	for t := node; t != nil && t.decided; {
		partner_seat := (t.hand + 2) % 4
		top := narr_top(t, t.rank)
		if !top && narr_card(nr, t.rank) != "low" {
			return .Adaptive
		}
		cash &&= top
		second := t.next
		if second == nil {
			break
		}
		answer: Maybe(string)
		for c in second.branches {
			if c == nil {
				continue
			}
			a := narr_answer(nr, c, partner_seat)
			if prev, have := answer.?; have && prev != a {
				return .Adaptive
			}
			answer = a
		}
		if !top {
			if a, _ := answer.?; a != "" && !strings.has_prefix(a, "low") {
				return .Adaptive // a low lead to an honour is a finesse, not a card given up
			}
		}
		_, third := narr_main_branch(second)
		if third == nil || third.next == nil {
			break
		}
		fourth := third.next
		next_lead: Maybe(string)
		for c in fourth.branches {
			if c == nil || !c.decided {
				continue
			}
			l := narr_lead(nr, c)
			if prev, have := next_lead.?; have && prev != l {
				return .Adaptive
			}
			next_lead = l
		}
		_, t = narr_main_branch(fourth)
	}
	return .Cash if cash else .Fixed
}

// One trick of the main path for the label: `A`, `low to Q`, `low to low`, `J to A`, `run the J`, or
// `duck` (a low card led, nothing in the other hand).
@(private)
narr_label_trick :: proc(nr: ^Narrator, lead: ^Policy_Node) -> string {
	third: ^Policy_Node
	if lead.next != nil {
		_, third = narr_main_branch(lead.next)
	}
	partner := -1
	if third != nil && third.decided {
		partner = third.rank
	}
	led := narr_card(nr, lead.rank)
	if partner >= 0 && nr.inv[partner] < nr.inv[lead.rank] {
		partner = -2 // the partner plays under the card led: that card is run (or cashed)
	}
	if partner >= 0 && narr_card(nr, partner) != "low" {
		return fmt.aprintf("%s to %s", led, narr_card(nr, partner), allocator = nr.alloc)
	}
	switch {
	case led == "low":
		return "low to low" if partner != -1 else "duck"
	case narr_top(lead, lead.rank):
		return led
	}
	return fmt.aprintf("run the %s", led, allocator = nr.alloc)
}

@(private)
Narr_Group :: struct {
	answer: string,
	groups: [RANKS + 2]bool,
}

@(private)
narr_group_add :: proc(answers: ^[dynamic]Narr_Group, answer: string, g: int) {
	for &a in answers {
		if a.answer == answer {
			a.groups[g] = true
			return
		}
	}
	x := Narr_Group {
		answer = answer,
	}
	x.groups[g] = true
	append(answers, x)
}

/*
One trick of the main path for the tooltip, and the next trick's lead node. Says the lead; then, per card
the second hand may show, what the leader's partner plays (cases with the same answer merged, the main one
first); then which fourth-hand cards change the next lead.
*/
@(private)
narr_tip_trick :: proc(nr: ^Narrator, b: ^strings.Builder, lead: ^Policy_Node, trick: int) -> ^Policy_Node {
	partner_seat := (lead.hand + 2) % 4
	strings.write_string(b, "Lead " if trick == 0 else "Then lead ")
	strings.write_string(b, narr_lead(nr, lead))

	second := lead.next
	if second == nil {
		strings.write_byte(b, '.')
		return nil
	}
	main_g, main_third := narr_main_branch(second)
	if main_third == nil {
		strings.write_byte(b, '.')
		return nil
	}

	// The partner's answer per second-hand card, grouped by answer, the main path's first.
	answers := make([dynamic]Narr_Group, 0, RANKS + 2, nr.alloc)
	narr_group_add(&answers, narr_answer(nr, main_third, partner_seat), main_g)
	for c, g in second.branches {
		if c != nil && g != main_g {
			narr_group_add(&answers, narr_answer(nr, c, partner_seat), g)
		}
	}
	if len(answers) == 1 {
		a := answers[0].answer
		switch {
		case a == "":
			fmt.sbprintf(b, " (%s has none).", SEAT_NAMES[partner_seat])
		case strings.has_prefix(a, "low"):
			fmt.sbprintf(b, " and play %s.", a)
		case:
			// `the Q from South` -> `to the Q in South`
			card := a[len("the "):strings.index(a, " from ")]
			fmt.sbprintf(b, " to the %s in %s.", card, SEAT_NAMES[partner_seat])
		}
	} else {
		strings.write_byte(b, '.')
		lho := SEAT_NAMES[second.order[1]]
		for a, i in answers {
			fmt.sbprintf(b, " %s %s ", "If" if i == 0 else "if", lho)
			narr_defender_cards(nr, b, second, a.groups)
			if a.answer == "" {
				fmt.sbprintf(b, ", %s has none to play", SEAT_NAMES[partner_seat])
			} else {
				fmt.sbprintf(b, ", play %s", a.answer)
			}
			strings.write_byte(b, ';' if i < len(answers) - 1 else '.')
		}
	}

	// The fourth hand, on the main path: the cards it may show that change the next lead.
	fourth := main_third.next
	if fourth == nil {
		return nil
	}
	main4, next := narr_main_branch(fourth)
	if next == nil || !next.decided {
		return next
	}
	main_lead := narr_lead(nr, next)
	switches := make([dynamic]Narr_Group, 0, RANKS + 2, nr.alloc)
	for c, g in fourth.branches {
		if c == nil || g == main4 || !c.decided {
			continue
		}
		if l := narr_lead(nr, c); l != main_lead {
			narr_group_add(&switches, l, g)
		}
	}
	rho := SEAT_NAMES[fourth.order[3]]
	for s in switches {
		fmt.sbprintf(b, " If %s ", rho)
		narr_defender_cards(nr, b, fourth, s.groups)
		fmt.sbprintf(b, ", lead %s next.", s.answer)
	}
	return next
}
