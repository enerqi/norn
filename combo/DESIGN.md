> Note (2026-07-30): this is the ORIGINAL BRIEF for the `combo` package, written while it lived in the
> bridge-bidding-system consumer (`deal-simulations/odin-sims`, as `Naive card combination analyser.md`). It
> moved here with the code. Two companions stayed in that consumer, because they are about the card PAGE and
> the published-table data rather than this engine: `COMBO_ANALYSER.md` (the implementation/handoff narrative
> for the analyser + the 2-hand advisor — source comments citing it mean that file) and
> `SUIT_COMBINATION_ENCYCLOPEDIA_HANDOFF.md` (the `suit_book` corpus registered through `book.odin`).

Naive card combination analyser

https://bridge.esmarkkappel.dk/main/main.html is the inspiration but we are doing a much simpler version.

naive because we are ignoring entries, just assuming can start in either hand whenever you like

for each of the 4 generated suits between north and south we want to generate tables of

- how likely to make 0 tricks
- how likely to make 1 tricks
- how likely to make n tricks, up to card count in the suit etc.

We should be able consider a target total trick count, e.g. 1 to 13
Given the best chances for different numbers of tricks in the 4 suits, what would be the best combination of plays 
to make across those 4 suits to reach the total.

This hints at the best line to make the total number of tricks.

When there is a par tricks calculation done by dds then can default to showing the best combinations to make that
number of tricks, but ultimately the total trick count is selectable and we can see the percentages per suit.
