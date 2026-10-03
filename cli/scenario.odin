package cli

/*
	scenario.odin — the named-scenario framework (generic, library-side).

	A `Scenario` pairs a `norn.Predicate` (a condition over a whole deal) with a name and a one-line
	description. The concrete scenarios are defined by the *consumer* (their bidding system); this
	package only provides the type and the driver that turns a `[]Scenario` registry into a runnable
	CLI. Keeping the framework here — and the definitions out — is what lets anyone reuse `norn`
	as a hand-generation engine with their own scenario set.
*/

import "../norn"

/*
One named simulation: a deal condition plus human-facing metadata.

TWO KINDS OF CONDITION, MODELLED AS A SUM. A COMPILED scenario's `predicate` is a `norn.Predicate` — a proc
written in Odin, checked by the compiler, costing nothing at run time; every scenario in this repository is
one. An INTERPRETED one's is a `norn.Interpreted_Predicate`: a walker plus the PROGRAM it walks, because a
condition parsed from a user's text file is a tree and Odin procs do not capture, so a bare
`proc(Deal_Summary) -> bool` has nowhere to keep it.

`norn.Condition` is the union of the two, so a scenario cannot be both and cannot be half of each. The
first version of this had two nullable fields plus a documented rule about which one won — the rule is
gone, and with it the state where a compiled predicate silently overrides an interpreted one.

Nothing here replaces anything: `predicate = proc(b: norn.Deal_Summary) -> bool { ... }` still compiles
untouched, because Odin converts a proc literal into the matching union variant implicitly.
*/
Scenario :: struct {
	name:        string,
	description: string,
	predicate:   norn.Condition,
}

// Was this scenario's condition parsed rather than compiled? What tells a user file's entries apart from
// the built-in registry when the two are concatenated into one list.
is_interpreted :: proc(s: Scenario) -> bool {
	_, interpreted := s.predicate.(norn.Interpreted_Predicate)
	return interpreted
}

// Human-facing page heading for a scenario: its one-line description when it has one, else the
// terse name. Used to title the exported HTML page (both `<title>` and the on-page `<h1>`).
scenario_title :: proc(s: Scenario) -> string {
	return s.description if s.description != "" else s.name
}

// Find a scenario by exact name in `registry`. Returns ok = false if none matches.
lookup :: proc(registry: []Scenario, name: string) -> (scenario: Scenario, ok: bool) {
	for s in registry {
		if s.name == name {
			return s, true
		}
	}
	return {}, false
}
