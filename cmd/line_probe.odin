package line_probe

/*
	line_probe.odin — one holding played layout by layout, the exact optimum against the fixed lines
	(`just combo-line-probe`; the work is `combo.line_probe`).

	  just combo-line-probe J3/KT9842                     every line, the layouts where any falls short
	  just combo-line-probe J3/KT9842 run finesse         just those lines
	  just combo-line-probe J3/KT9842 all=1 run           every layout, not only the short ones

	A holding is North's cards, a slash, South's: ranks 2-9 T J Q K A, in any order ("-" for a void).
*/

import "core:fmt"
import "core:os"
import "core:strings"

import "../combo"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: line_probe NORTH/SOUTH [all=1] [line ...]   e.g. line_probe J3/KT9842 run finesse")
		os.exit(2)
	}
	north_s, _, south_s := strings.partition(os.args[1], "/")
	north, ok_n := parse_cards(north_s)
	south, ok_s := parse_cards(south_s)
	if !ok_n || !ok_s || north & south != 0 {
		fmt.eprintfln("line_probe: %q is not a holding (NORTH/SOUTH, ranks 2-9 T J Q K A, no card in both)", os.args[1])
		os.exit(2)
	}
	diff_only := true
	names := make([dynamic]string)
	for arg in os.args[2:] {
		if arg == "all=1" {
			diff_only = false
		} else {
			append(&names, arg)
		}
	}
	if len(names) == 0 {
		for l in combo.candidate_lines() {
			append(&names, l.name)
		}
	}
	b := strings.builder_make()
	if !combo.line_probe(&b, north, south, names[:], diff_only) {
		fmt.eprintln("line_probe: the optimal search ran over its budget on this holding")
		os.exit(1)
	}
	fmt.print(strings.to_string(b))
	opt, _ := combo.sd_optimal_expected_tricks(north, south)
	fmt.printfln("expected tricks: optimum %.3f", opt)
	for l in combo.candidate_lines() {
		for name in names {
			if name == l.name {
				fmt.printfln("  %-22s %.3f", l.name, combo.expected_tricks(combo.sd_line_distribution(north, south, l).p))
			}
		}
	}
}

parse_cards :: proc(text: string) -> (m: u16, ok: bool) {
	if text == "-" {
		return 0, true
	}
	for c in text {
		r := strings.index_rune("23456789TJQKA", c)
		if r < 0 {
			return 0, false
		}
		m |= u16(1) << uint(r)
	}
	return m, true
}
