#+build js
package combo

// The wasm player has no suit-solver table: the baked one (suit_solver_table_data.odin) is megabytes of
// tooltips, and the player's single page would carry them all. Every lookup misses, and the engine's own
// line is shown, as before the table existed.

@(rodata)
SUIT_SOLVER_TABLE := [?]Solver_Table_Entry{}

@(rodata)
SUIT_SOLVER_JOINT := [?]u16{}
