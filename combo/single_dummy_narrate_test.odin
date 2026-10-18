#+build !js
package combo

/*
	single_dummy_narrate_test.odin — golden narrations of certified lines (single_dummy_narrate.odin).

	Each was read by hand when recorded: a two-round line with a duck first (T86/AQ972) and a finesse then a run
	(JT7/AK653), from 2026-10-14/15; and, from 2026-10-18, when the repaired finesse lines took four of the old
	six: cash the king then finesse the ten (AKT6/J975), low toward each honour in turn (Q53/J8762), duck the first
	round unless West plays the J or T, then toward the Q, then the K (K74/Q9865; AT64/Q9852 until the
	discovery line took it the same day), and duck, then toward the king, then run the nine (T982/K743). A
	changed string is a changed line or changed words: read the new one before re-recording it. A golden that
	stops having a searched line has been taken by a fixed line - check that the fixed line really is as good
	before replacing it.
*/

import "core:testing"

@(test)
test_narrations :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Golden :: struct {
		n, s:       u16,
		label, tip: string,
	}
	goldens := []Golden {
		{0x0150, 0x14a1, "Play low to low then low to Q then 10 to A", "Lead low from North. If East plays low or shows out, play low from South; if East plays the K, play the A from South; if East plays the J, play the Q from South. Then lead low from North. If East plays the J or low, play the Q from South; if East plays the K, play the A from South; if East shows out, play low from South. Then lead the 10 from North to the A in South. Then cash your winners. Chances vs best defence: 5 tricks 14%, 4 tricks 76%, 3 tricks 100%."},
		{0x0320, 0x181a, "Play low to K then run the 10 then J to A", "Lead low from North. If East plays the Q or low, play the K from South; if East shows out, play low from South. Then lead the 10 from North. If East plays low or shows out, play low from South; if East plays the Q, play the A from South. Then lead the J from North to the A in South. Then cash your winners. Chances vs best defence: 5 tricks 40%, 4 tricks 96%, 3 tricks 100%."},
		{0x1910, 0x02a8, "Play K then low to 10", "Lead the K from North and play low from South. If West plays the Q or shows out, lead low from North next. Then lead low from South. If West plays the 8 or low, or shows out, play the 10 from North; if West plays the Q, play the A from North. If East plays the Q, lead low from North next. If East shows out, lead the 9 from South next. Then cash your winners. Chances vs best defence: 4 tricks 53%, 3 tricks 100%. No line does better."},
		{0x040a, 0x0271, "Play low to Q then low to J", "Lead low from South. If West plays the 10, 9 or low, or shows out, play the Q from North; if West plays the A or K, play low from North. Then lead low from North. If East plays the 10 or 9, play the J from South; if East plays the A or K, or shows out, play low from South. Then play the rest out. Chances vs best defence: 3 tricks 43%, 2 tricks 92%, 1 trick 100%. No line does better."},
		{0x0824, 0x04d8, "Play low to low then low to Q then run the K", "Lead low from South. If West plays the A or low, play low from North; if West plays the J or 10, or shows out, play the K from North. If East plays the J or 10, lead the K from North next. If East shows out, lead low from South next. Then lead low from North. If East plays the J or 10, play the Q from South; if East plays the A or shows out, play low from South. Then lead the K from North and play low from South. Then cash your winners. Chances vs best defence: 4 tricks 12%, 3 tricks 94%, 2 tricks 100%."},
		{0x01c1, 0x0826, "Play low to low then low to K then run the 9", "Lead low from North. If East plays the A or low, or shows out, play low from South; if East plays the Q or J, play the K from South. Then lead low from North. If East plays the Q or J, play the K from South; if East plays the A or shows out, play low from South. Then lead the 9 from North and play low from South. Then cash your winners. Chances vs best defence: 2 tricks 83%, 1 trick 100%. No line does better."},
	}
	for g in goldens {
		c := sd_certified_line(g.n, g.s)
		defer sd_certified_destroy(&c)
		label, tip, ok := sd_narrate(&c, g.n, g.s)
		testing.expectf(t, ok, "%04x/%04x should have a searched line", g.n, g.s)
		testing.expectf(t, label == g.label, "%04x/%04x label:\n  got  %q\n  want %q", g.n, g.s, label, g.label)
		testing.expectf(t, tip == g.tip, "%04x/%04x tip:\n  got  %q\n  want %q", g.n, g.s, tip, g.tip)
	}
}

// A fixed line has no policy: the engine's own narration says it.
@(test)
test_a_fixed_line_is_not_narrated_here :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := sd_certified_line(0x1400, 0x0003) // AQ opposite 32: the fixed finesse is already best
	defer sd_certified_destroy(&c)
	testing.expect_value(t, c.source, Line_Source.Fixed)
	_, _, ok := sd_narrate(&c, 0x1400, 0x0003)
	testing.expect(t, !ok, "a fixed line should be left to describe_suit_line")
}
