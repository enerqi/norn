#+build !js
package combo

/*
	single_dummy_narrate_test.odin — golden narrations of certified lines (single_dummy_narrate.odin).

	Each was read by hand when recorded (2026-10-14, three replaced 2026-10-15 when better fixed lines took
	theirs): a two-round line with a duck first (T86/AQ972), a finesse then a run (JT7/AK653), a finesse of
	the ten (QT/AK742), a duck then running the nine through K Q (AJT873/92, proven optimal), ducking twice
	after a finesse (6/AQ542) and a repeated finesse (AQJT42/63). Four of the six are relabelled lines, so
	their cards are named back through the rank map. A changed string is a changed line or changed words:
	read the new one before re-recording it.
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
		{0x0500, 0x1825, "Play low to 10 then Q then K", "Lead low from South. If West plays low or shows out, play the 10 from North; if West plays the J, play the Q from North. Then lead the Q from North and play low from South. If West shows out, lead low from South next. Then lead the K from South (North has none). If East shows out, lead the A from South next. Then cash your winners. Chances vs best defence: 5 tricks 42%, 4 tricks 92%, 3 tricks 100%."},
		{0x1362, 0x0081, "Play low to low then run the 9", "Lead low from South. If West plays low or shows out, play low from North; if West plays the K or Q, play the A from North. If East shows out, lead low from North next. Then lead the 9 from South. If West plays low or shows out, play low from North; if West plays the K or Q, play the A from North. If East shows out, lead low from North next. Then cash your winners. Chances vs best defence: 5 tricks 68%, 4 tricks 100%. No line does better."},
		{0x0010, 0x140d, "Play low to Q then duck twice", "Lead low from North. If East plays the J, 10, 9, 8, 7 or 3, play the Q from South; if East plays the K or shows out, play low from South. Then lead low from South (North has none). Then lead low from South (North has none). If East shows out, lead low from South next. Then cash your winners. Chances vs best defence: 3 tricks 31%, 2 tricks 81%, 1 trick 100%."},
		{0x1705, 0x0012, "Play low to 10 then low to J", "Lead low from South. If West plays low, play the 10 from North; if West plays the K, play the A from North; if West shows out, play low from North. If East plays the K, lead the J from North next. If East shows out, lead low from North next. Then lead low from South. If West plays low or shows out, play the J from North; if West plays the K, play the A from North. If East plays the K, lead the Q from North next. If East shows out, lead low from North next. Then cash your winners. Chances vs best defence: 6 tricks 37%, 5 tricks 96%, 4 tricks 100%."},
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
