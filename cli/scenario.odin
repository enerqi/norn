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

// One named simulation: a deal condition plus human-facing metadata.
Scenario :: struct {
	name:        string,
	description: string,
	predicate:   norn.Predicate,
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
