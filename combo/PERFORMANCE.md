> Note (2026-07-30): moved here from the bridge-bidding-system consumer with the `combo` package. Source
> comments citing `PERFORMANCE.md` mean this file; ones citing `COMBO_ANALYSER.md` mean the consumer's
> `deal-simulations/odin-sims/COMBO_ANALYSER.md`, which stayed there with the card page.

# combo package — performance analysis

*Read the code (combo.odin, single_dummy.odin, lines.odin, single_dummy_opt.odin, combine.odin)
before this document. This is not a tutorial.*

---

## 0. Status — what shipped, and where the original analysis was wrong

`annotate(.Html_Cards)` end-to-end: **471 ms → 12.6 ms per deal (37×)**, output byte-identical
(verified by diffing a fixed-seed `1major-game-force` render before/after every step, and the threaded
build against the serial `-define:COMBO_THREADS=false` build — including an n=48 batch on a second seed),
38 combo tests green, no leaks (sim's tracking allocator). Measured with `just bench`
(Odin `-o:speed -microarch:native`).

Shipped, in order:

| # | change | section | measured effect |
|---|---|---|---|
| 1 | §2 redundancy: evaluate candidate lines once/partnership, not ~5× | §2 | 471 → 154 ms |
| 2 | Phase-1 terminal-skip: compute terminal positions before the memo, don't cache them | §4.2 | ~3% |
| 3 | Phase-2 `sd_trick` memo: lead-point memo keyed `(layout, trick_no)` → u64, shared across the 2^m splits | §4.3 | p2 lines 1.7–2.5×; annotate 154 → 92 ms |
| 4 | Option A map reuse: one scratch map `clear()`d across the 4 census suits and the 20 gather evals | §8.2 | per-deal map alloc/free 48 → 4; annotate 92 → 83 ms |
| 5 | Equivalence-class split enumeration: solve one representative per (per-block East-count) pattern, weighted by ∏ C(block, k), instead of all 2^m submasks | §4.2, §4.4 | p1 8m 20×, p2 8m 30–42×; annotate 83 → 39 ms |
| 6 | Intra-deal threading (coarse): the 4 per-partnership units (census ×2, SD bundle ×2) on **fresh threads spawned per deal** | §9.4 | annotate 38 → 15 ms (2.5×) |
| 7 | Persistent pool + per-worker scratch (PERF #1 coarse + #2): reuse a `thread.Pool` across deals; per-worker heap memos (`clear()`-reused, freed once by `shutdown`) + BSS temp arena ⇒ **zero heap allocs/deal** | §8.2, §9.4 | annotate ~neutral (15 → 16.3 ms) — coarse is critical-path bound, see below |
| 8 | Fine-grained per-SUIT tasks: split each partnership's census + SD gather to the suit level → **16 independent tasks/deal**, assembled via shared `finish_census`/`finish_sd` | §9.4 | annotate 16.3 → **12.6 ms**; ratio vs serial 2.5× → **3.2×** |

**Change 7 was measured NEUTRAL — a second falsified premise (cf. the §1/§4.4 correction).** The approved
plan assumed per-deal thread *spawn* was the 2.5×-vs-3.7× gap. It was not: on Windows `thread.create` is cheap,
and a persistent pool at the SAME coarse 4-unit granularity ran ~1 ms *slower* (16.3 vs 15 ms, both consistent).
The real ceiling is **unit imbalance** — coarse wall-time = the single longest unit (one SD bundle's four serial
suit-gathers), which no coarse scheme can beat. Change 8 (fine-grained, the user's call once the coarse result
came in) attacked that: at the suit level the critical path is ONE suit, so >4 cores engage. The pool + PERF #2
still ship (they enable change 8 and remove per-batch spawn + steady-state allocs), just not for coarse speed.
The residual 12.6 ms floor is now the **serial main-thread tail** (the two `adaptive_curve_from` joint DPs +
JSON writing) plus task imbalance (8 heavy census suits vs 8 light SD suits) — see §9.4 / §10.

An earlier revision of change 7 backed the memos with a fixed **BSS arena** (to avoid any heap alloc). A 1 MB
arena silently overflowed mid-warmup → map grows failed → the memo dropped entries → correct-but-slow (annotate
35 ms, parity still byte-identical because the memo is a pure cache). The lesson: never back a *growing* map with
a fixed arena. Shipped version keeps memos on the heap (no ceiling) and frees them via a `shutdown` registry.

**The original premise (below) was wrong on one central point.** §1/§4.4 claimed Phase 1 is cheap
and Phase 2 dominates. Measured, it was the reverse: one `suit_trick_distribution` (Phase-1 census)
cost **~5.8 ms** at 6 missing cards — more than all five Phase-2 candidate lines combined. The reason
(profiled, §4.2): the census enumerated all 2^m E/W splits with NO card abstraction → ~86k distinct
minimax layouts for a single 6-missing suit. Change 5 (equivalence-class enumeration) attacked that
root — solving one representative per pattern — and cut Phase-1 8-missing 20× and the whole 2^m loop
in BOTH phases. After all five changes the two halves (Phase-1 census, Phase-2 gather) are balanced
and small; the next lever is threading (§9), not more scalar work.

The per-call microbenchmarks in the tables further down were measured with the ORIGINAL code; the
prose has been corrected where it contradicted measurement, but treat any absolute µs figure as
"as originally written" unless it cites change 1–4.

---

## 1. Hot-path map (where time goes)

For a single deal in `Html_Cards` format the call tree is roughly:

```
annotate (Html_Cards)
├─ analyse_ns (NS)                           Phase 1, 4 suits
│   └─ suit_trick_distribution × 4          2^m submask loop → suit_dd_tricks (memoised minimax)
├─ analyse_ns (EW)                           Phase 1, 4 suits
│   └─ suit_trick_distribution × 4
│
├─ write_suits_json_sd (NS)                  Phase 2, calls best_line_by_mean × 4
│   └─ best_line_by_mean × 4 → candidate_lines(5) × sd_line_distribution  [20 calls]
├─ write_suits_lines_json (NS)               DUPLICATE: best_line_by_mean × 4   [20 more]
├─ write_suits_tips_json (NS)                DUPLICATE: best_line_by_mean × 4   [20 more]
│
├─ write_suits_json_sd (EW)                  [20 calls]
├─ write_suits_lines_json (EW)               [20 more]
├─ write_suits_tips_json (EW)                [20 more]
│
├─ adaptive_at_least_curve (NS)              gather_candidates(NS) + dp_value × 14
│   └─ gather_candidates → suit_candidate_lines × 4 → sd_line_distribution × 5  [20 calls]
└─ adaptive_at_least_curve (EW)              [20 calls]
```

Historically **sd_line_distribution calls per deal: 160** (the 5-line eval triplicated across the
writers × 2 partnerships). After the §2 fix that is **40** (one gather per partnership), and after
the §4.3 memo each of those 40 is ~2× cheaper.

Phase 1 suit_trick_distribution calls: 8 per deal — and MEASUREMENT (see §0) shows these dominate,
not Phase 2. One census call is ~5.8 ms at 6 missing cards vs ~0.12 ms for a single Phase-2 line.
The original claim here ("cheap relative to Phase 2") was backwards; it is corrected in §4.2/§4.4.

---

## 2. Redundancy: the biggest win — SHIPPED (471 → 154 ms)

**Done.** `annotate` now calls `build_partnership_sd` once per partnership (combo.odin), which runs
`gather_candidate_tables` once and caches the best-by-mean line, its marginal, and every candidate's
joint table. The four writers (`write_suits_json_sd`/`_lines`/`_tips`), the SD total
(`sd_joint_total_of`), and the make curve (`adaptive_curve_from`) all read from that struct instead
of re-enumerating. Split-enumerations per deal dropped from ~208 to ~40. Output byte-identical
(the joint-table marginal sums the same exact-integer split weights as the old `sd_line_distribution`
— all partial sums ≤ C(26,13), exact in f64). Estimated 4–5× on the Phase-2 portion; actual whole-
deal effect was 3.06× because Phase 1 (not deduped, and larger than assumed) is the remaining floor.

Original analysis follows.

`write_suits_json_sd`, `write_suits_lines_json`, and `write_suits_tips_json` each independently
call `best_line_by_mean` (which evaluates all 5 candidate lines) for the same 4 suits of the
same partnership. `adaptive_at_least_curve` then calls `gather_candidates` (same 5 lines, same
4 suits) a fourth time. That is **4× recomputation of the same 20 sd_line_distribution calls**
per partnership, and the partnership loop doubles it to 8×.

Fix: compute `gather_candidates` once per (partnership, deal), store `[4][]Line_Result`, and
pass it into the four writers. The `annotate` proc already holds both `Deal_Analysis` results
(`a`, `ew`); adding the candidate slices is straightforward. Estimated reduction: ~75% of all
Phase 2 work eliminated with zero algorithmic change.

---

## 3. Data structures

### 3.1 Phase 1 memo: `map[Suit_Layout]int`

`Suit_Layout = [4]u16` = 8 bytes = same width as `u64`. Odin hashes the same 8 bytes either
way, so "packing" the four masks into a `u64` is a no-op for hash performance — the key is
already one word.

The only meaningful change here is the **value**: `int` is 8 bytes on 64-bit; tricks fit in
`i8` (1 byte). `map[Suit_Layout]i8` would shrink each map entry by 7 bytes, improving cache
density for large memos. Whether Odin's map pads the value to alignment is unclear without
inspecting the runtime — benchmark before concluding this matters.

The memo is private to `suit_trick_distribution`, reset per (north, south) pair, and grows to
at most a few thousand entries per suit (positions converge fast). Cache pressure on the memo
is not the main cost here.

### 3.2 opt_key: string from sort + serialize

`opt_key` (single_dummy_opt.odin:64–89) allocates a temp slice, sorts it O(n log n), then
serializes to bytes. This is called on every `opt_solve` entry before the memo lookup — the
most frequent point in the optimal-search recursion.

The string is immediately used as a map key and discarded. Better:

1. Sort the worlds slice **in-place** before the call so the caller controls allocation.
2. Replace the string map with `map[u64]Vec` keyed on a fast hash (FNV-1a or wyhash) computed
   inline from the already-sorted raw bytes. A collision is not safety-critical (it degrades to
   recomputing a subtree, not wrong output), so a 64-bit hash is acceptable.
3. Or: pack the `(e, w)` mask pairs into a sorted array of `u32`s (13 bits each, ~2 per `u32`),
   hash those bytes. The `wt` fields could be bucketed if exact floating-point keys are
   problematic.

Savings: eliminates O(n log n) sort + O(n × 16-byte) allocation + full string comparison on
every memo lookup in the hot opt_solve recursion.

### 3.3 `Vec = [RANKS+1]f64 = [14]f64 = 112 bytes`

Unaligned. Odin's default struct alignment is the largest field (8 bytes). `[14]f64` at 8-byte
alignment leaves 0 bytes of tail padding. Fine for AVX (requires 32-byte alignment for `vmovapd`
but 16-byte for `vmovupd`). Explicit `#align(32)` on arrays used in SIMD hot loops would
eliminate unaligned load penalties. Not critical unless SIMD is added.

### 3.4 `Suit_Trick_Dist.p: [14]f64` and `Deal_Analysis`

`[14]f64 × 4 suits + [14]f64 total` = 70 × 8 = 560 bytes per `Deal_Analysis`. Passed and
returned by value throughout. Stack-friendly; no issues.

---

## 4. Algorithm analysis

### 4.1 Submask enumeration (`suit_trick_distribution`, `sd_line_distribution`)

```odin
east = (east - 1) & missing  // Gosper-style
```

Correct and asymptotically optimal: exactly 2^m iterations for m missing cards. m ≤ 8 in almost
all practical holdings (a 5-card suit leaves 8 opponents' cards). 2^8 = 256 iterations —
negligible. The concern is not the iteration count but the cost per iteration (the minimax call
or fixed-line evaluation).

### 4.2 `suit_dd_tricks` / `play_card` — double-dummy minimax (THE remaining bottleneck)

MEASURED: one `suit_trick_distribution` is ~5.8 ms (6 missing) / ~14 ms (8 missing) — the single
most expensive call in the package, and after §2/§4.3/§8.2 the dominant cost in `annotate` (8 calls
per deal). This contradicts the original "cheap relative to Phase 2" framing throughout §1/§4.4.

**Terminal-skip — SHIPPED.** `suit_dd_tricks` now computes the two terminal cases (`ns_cards == 0`,
`ew_cards == 0`) BEFORE any memo access and does not cache them — the minimax bottoms out at
terminals constantly, and each is one popcount, far cheaper than a map lookup + insert. Effect: ~3%.
That it was ONLY ~3% is the important diagnostic: **map traffic is not the bottleneck — raw minimax
node count is.** Cutting further needs node reduction, not allocator/cache tweaks.

The recursion is memoised by `Suit_Layout`. Positions recur heavily (two different EW splits
often converge to the same layout after a few cards are played), so the memo is effective.
`play_card` allocates `next: Suit_Layout` on the stack every call (an 8-byte copy). Cheap.

The set-bit iteration pattern:
```odin
m := holding
for m != 0 {
    r := int(intrinsics.count_trailing_zeros(m))
    m &= m - 1
    ...
}
```
is the canonical efficient approach. No improvement possible here.

**Equivalence-class enumeration — SHIPPED (p1 8m 20×), the node-count fix.** Profiling one
`suit_trick_distribution` (throwaway `-define:COMBO_PROFILE` counters, since removed) showed the cost
is NOT map traffic (terminal-skip proved that) but the **~86k distinct minimax layouts** (6 missing)
/ **~185k** (8 missing) produced by enumerating all 2^m E/W splits with no card abstraction — at
~2.2 ns per `play_card` node, pure node count. Fix: the opponents' missing cards separated by NS
cards form equivalence blocks (a maximal run of missing ranks with no NS card between them is
interchangeable for DD); enumerate the distinct per-block (East-count) PATTERNS, solve ONE
representative each, weight by ∏ C(block, k) concrete splits. Exact (integer multiplicities, same
East length ⇒ same vacant-space weight per class), byte-identical output, minimax untouched (so no
census-correctness risk), and it collapses BOTH phases' 2^m loop (see `Split_Iter`, combo.odin).
6-missing solid block: 64 splits → 7 patterns; 8-missing: 256 → 9. Degenerates to the full 2^m only
for pathological all-singleton holdings, where multiplicities are all 1 — never slower.

**Alpha-beta pruning — now LOW value, not pursued.** It would prune the ~31 within-layout `play_card`
nodes but not the distinct-layout explosion that equivalence-class enumeration already removed. A
transposition table with bound/exact flags is real work with census-correctness risk for a small
remaining gain. Skip unless a future profile shows within-layout branching dominating.

**Trick-count bound** — a cheaper partial (in `play_card`, stop once `best` hits an upper bound on
remaining NS tricks = rounds left = `max` seat card-count; NOTE `max(lenN,lenS)` is NOT valid
mid-position). Fires mainly on solid suits, which are already cheap post-equiv-class. Low value.

### 4.3 `sd_trick` — fixed-line evaluator memo — SHIPPED (p2 lines 1.7–2.5×)

**Done.** `sd_from_lead` now memoises each declarer-on-lead position, keyed on the full four-hand
layout + `trick_no` packed into a **u64** (`sd_key`: 4×13 rank bits + 4 trick bits, no padding).
At a lead point the fixed line is a pure function of public state = `(layout, trick_no)`, so two E/W
splits reaching the same layout at the same trick take the same value — always safe to share, never
wrong (the past is irrelevant once the current layout matches). Terminals are returned before the
memo (like §4.2). The memo is created once per `sd_line_distribution` / `sd_line_joint_table` call
and shared across all 2^m splits; it must NOT cross lines (different pure function), which §8.2's
`clear()`-reuse enforces. Measured: p2 single line 6m 202→118 µs, 8m 2636→1036 µs; 5-candidate
gather 8m 12896→5296 µs; adaptive curve 42→14 ms/deal.

### 4.4 `sd_line_distribution` call count vs Phase 1 (original claim was BACKWARDS)

The original text here concluded "Phase 2 is roughly 5–20× more expensive per suit than Phase 1."
MEASUREMENT says the opposite, both before and after the §4.3 memo: at 6 missing cards Phase 1 is
~5.8 ms while a single Phase-2 line is ~0.12 ms and all five candidates ~0.6 ms. Phase 1 is the
expensive one because its per-split minimax explores a real game tree (declarer AND defenders
branch), whereas a Phase-2 line fixes declarer's play so only defenders branch. The §2 dedup and the
§4.3 memo made Phase 2 cheaper still; the census is untouched and now dominates (§4.2).

### 4.5 `opt_defender` / `assign_rec` — partial-observability defender

The product of canonical plays across all active worlds grows fast. The ASSIGN_CAP = 20,000
limit terminates it. Within budget, `assign_rec` allocates `groups[RANKS]` as 13 dynamic arrays
on the temp allocator every leaf — each leaf is cheap but they accumulate.

The `canonical_plays` function is O(13) per world — negligible.

The main opt-search memory pressure is the `memo: map[string]Vec` living in
`context.temp_allocator`: both the string keys (variable length) and `Vec` values (112 bytes)
are temp-allocated. For a budget of 1.5M nodes with good memo hit rates the actual allocation is
much smaller, but repeated short-lived keys pile up in temp until `free_all`.

### 4.6 DP in `dp_value`

O(4 × 14 × L × 14) where L ≤ 5 candidate lines. Total: ~3920 f64 multiplications. Negligible.
The inner loop is a sliding dot product (cross-correlation):

```odin
for b in 0..=RANKS-a {
    s += L.dist.p[b] * h[a + b]
}
```

This is a textbook SIMD cross-correlation. With AVX2 it could process 4 values of `b`
simultaneously. But since the DP total cost is ~4 µs even scalar, SIMD here saves nothing
meaningful unless the candidate count grows by 100×.

### 4.7 `best_fixed_combination` search

Up to 5^4 = 625 combinations, each requiring 3 `convolve` calls. With the outer two levels
sharing intermediate convolutions (`ab = convolve(a, b)` hoisted), only 5^2 + 5^2 + 5
= 55 actual convolutions. Already done this way in the code (see `ab`, `abc` temporaries).
The search is negligible.

---

## 5. SIMD opportunities

SIMD is worth considering only after the §2 redundancy fix. The remaining hot loops:

### 5.1 `convolve` — 14×14 multiply-add

```odin
out[i+j] += a[i] * b[j]  // for 0<=i,j, i+j<=13
```

This is a 14×14 lower-triangular FMA pattern. The inner `j` loop (length 14-i) fits in 4
AVX2 f64 lanes (`ymm` = 4 × f64). Unrolled SIMD version:

```
for each i (14 iters):
    broadcast a[i] into ymm0
    load  b[0..3]  → ymm1; fmadd ymm1,ymm0 → out[i..i+3]
    load  b[4..7]  → ymm1; fmadd ...
    load  b[8..11] → ymm1; fmadd ...
    scalar tail for b[12..13]
```

14 broadcasts + ~56 fmadd ops → ~4 AVX2 instructions per `i` → 56 instructions total vs ~196
scalar. Gain: ~3.5× for `convolve`. In the current code `convolve` is called ≤ 4 times per deal
(Phase 1) plus a few more in `best_fixed_combination`. Net impact on a 48-deal batch: small but
measurable.

### 5.2 `vec_add` / `vec_mean` — length-14 f64 vectors

`vec_add`: 14 scalar adds → 4 AVX2 adds (trivial). Called in `assign_rec` leaf (opt solver).
`vec_mean`: dot product with 0..13 weights → 4 FMA + hadd. Not a bottleneck but trivial to
vectorize.

### 5.3 Batch Phase 2 evaluations across splits

The highest-leverage SIMD idea: process 4 EW splits simultaneously through `sd_trick`. Since the
declarer's line choices are the same for all splits sharing the same public state (NS cards +
played mask), the 4-wide simulation would be identical on declarer nodes and independent on
defender nodes. This requires rewriting the sim to carry a `[4]Suit_Layout` state — a non-trivial
refactor but potentially a 4× speedup on the 2^m split loop. Most practical gain for suits with
m ≥ 5 missing cards (real suits with 4–8 card length in one hand).

### 5.4 `line_dominates` / `dist_near_equal`

Both compute 14 `p_at_least` values (prefix sums of a 14-element array) and compare them.
The prefix sum is a scan — not directly SIMD with a plain add — but a Kogge-Stone prefix-sum
in AVX2 is 4 passes and eliminates the scalar loop. Negligible since n=5 candidates.

---

## 6. Allocation patterns

| Site | Pattern | Notes |
|---|---|---|
| Phase 1 memo | `make(map[...])` + `defer delete` per suit | One alloc per suit_trick_distribution call; reasonable |
| Phase 2 line loop | `sd_line_distribution` allocates nothing (pure stack) | Good |
| `suit_candidate_lines` | `make([]Line_Result, ...)` | Caller owns; passed into pareto/DP |
| `gather_candidates` | calls `suit_candidate_lines × 4` on `temp_allocator` | Freed by free_all |
| `opt_key` | clone+sort worlds on temp + string builder on temp | Called O(budget) times in opt solver |
| `assign_rec` leaf | `groups[13]` dynamic arrays on temp | Temp-allocated; freed on free_all |
| `opt_solve` memo | `map[string]Vec` on temp | Lives for the duration of one opt call |
| `annotate Html_Cards` | `free_all(context.temp_allocator)` at end | Correct — cleans up all of the above |

The `context.temp_allocator` usage is correct and consistent. The opt solver is the only site
with significant temp pressure (string keys × budget). If the solver is called per-suit × 4 ×
2 partnerships per deal, and budget = 1.5M (rarely hit — most suits fall back before then), the
temp allocation is bounded. No leaks.

The `write_suits_json_sd` / `write_suits_lines_json` / `write_suits_tips_json` chain allocates
`best_line_by_mean` results on the default allocator but immediately uses them inline and doesn't
store them — no accumulation issue. After the §2 redundancy fix those calls disappear anyway.

---

## 7. Benchmark recommendations

Odin's `core:time` package provides `time.tick_now()` + `time.tick_diff()`. Benchmark procs:

```odin
import "core:time"

bench_phase1_suit :: proc() {
    // Fixed known holding: 7 missing cards (realistic worst case)
    // north = 0b0000001100000 (J T), south = 0b0001000000000 (A)
    // missing = 10 cards
    start := time.tick_now()
    N :: 1000
    for _ in 0..<N {
        _ = suit_trick_distribution(0x600, 0x1000)
    }
    elapsed := time.tick_diff(start, time.tick_now())
    fmt.printf("phase1 suit (7 missing): %.1f µs/call\n",
        f64(time.duration_microseconds(elapsed)) / N)
}

bench_phase2_line_distribution :: proc() {
    start := time.tick_now()
    N :: 200
    for _ in 0..<N {
        _ = sd_line_distribution(0x600, 0x1000, line_finesse)
    }
    elapsed := time.tick_diff(start, time.tick_now())
    fmt.printf("phase2 sd_line_dist (7 missing): %.1f µs/call\n",
        f64(time.duration_microseconds(elapsed)) / N)
}

bench_candidate_lines_4_suits :: proc() {
    // A realistic NS pair: fill in hand summaries from a real deal
    north := norn.Hand_Summary{ ... }
    south := norn.Hand_Summary{ ... }
    start := time.tick_now()
    N :: 100
    for _ in 0..<N {
        cand := gather_candidates(north, south, context.temp_allocator)
        free_all(context.temp_allocator)
        _ = cand
    }
    elapsed := time.tick_diff(start, time.tick_now())
    fmt.printf("gather_candidates (4 suits): %.1f µs/call\n",
        f64(time.duration_microseconds(elapsed)) / N)
}

bench_annotate_html_cards :: proc() {
    // Use a real board from the sim corpus
    board := /* ... real norn.Deal ... */
    b := strings.builder_make()
    start := time.tick_now()
    N :: 10
    for _ in 0..<N {
        strings.builder_reset(&b)
        annotate(&b, board, .Html_Cards)
    }
    elapsed := time.tick_diff(start, time.tick_now())
    fmt.printf("annotate Html_Cards end-to-end: %.1f ms/deal\n",
        f64(time.duration_milliseconds(elapsed)) / N)
}
```

Interesting parameter axes:
- `m` = number of missing cards (0–13): the most important variable. Plot µs vs m.
- Holding shape (AKQ solid vs Q985 tenace vs void): affects minimax tree size.
- Per-suit vs per-deal: isolate Phase 1 vs Phase 2 vs DP.
- With/without §2 redundancy fix: expected ~4–5× speedup on annotate end-to-end.

Build flags for benchmarks: `odin build . -o:speed` (not `-o:none` which disables inlining and
all optimizations).

---

## 8. Memory allocation analysis

### 8.1 Lifetime taxonomy

```
Process          — nothing; no combo globals except g_binom (stack-init, read-only)
Batch/scenario   — nothing in combo; norn owns the batch loop
Per-deal         — Phase 1 memos (currently default allocator), opt-solver structures (temp)
Per-suit         — Phase 1 memo MAP OBJECT (alloc+delete, default allocator)
Stack-only       — sd_line_distribution, sd_trick, play_card, convolve, dp_value, all vec ops
```

All allocations in combo touch one of two allocators: the **default allocator** (Phase 1 memos)
or `context.temp_allocator` (everything else). `annotate(.Html_Cards)` calls
`free_all(context.temp_allocator)` at the end — the single reset point for all temp allocations
of a deal.

### 8.2 Memo reuse — Option A SHIPPED (per-deal map alloc/free 48 → 4)

**Done, both phases.** Two hot loops now thread ONE caller-owned scratch map, `clear()`d on entry:
- `analyse_ns` creates one `map[Suit_Layout]int` and passes it to `suit_joint_table` across the 4
  census suits (each suit clears it — the four Suit_Layout spaces are independent).
- `gather_candidate_tables` creates one `map[u64]int` and passes it to `sd_line_joint_table` across
  all 4×5 = 20 (suit × line) evaluations (each clears it — the memo must not cross lines, §4.3).

Both take an optional `memo_in: ^map = nil`; `nil` keeps the old make/delete for standalone callers
(tests, `best_line_by_mean`, `sd_best_joint_table`). Per deal, map make/delete dropped from ~48
(8 census + 40 sd) to **4** (2 `analyse_ns` + 2 `gather_candidate_tables`). Backing storage grows
once to the high-water mark and is reused via `clear`. Effect: annotate 92 → 83 ms. Byte-identical.

FURTHER — DONE (change 7, §0). Steady-state per-deal heap allocation is now **zero**. With the persistent
pool (§9.4) each worker keeps its scratch in THREAD-LOCAL storage for the process lifetime: the two minimax
memo maps on the heap (`make`d once, `clear()`-reused every deal — never deleted mid-run) plus a per-deal TEMP
arena backed by a fixed BSS array (`[256 KB]u8`, reset with `mem.free_all` after each task). So after warmup a
deal allocates nothing; the only per-thread heap objects are the two memo maps' backing, freed ONCE by
`combo.shutdown` (below). The census/SD `memo_in` params (`analyse_ns`, `gather_candidate_tables`,
`suit_joint_table`, `sd_line_joint_table`) thread the persistent map down; all `clear()` on entry, so reuse is
byte-identical to a fresh map (pure cache).

Two design points that bit and were corrected (see §0):
- **Memos stay on the heap, NOT in the BSS arena.** A growing map in a fixed arena silently drops entries on
  overflow → correct but slow. Only the bounded temp scratch (candidate tables ~32 KB ≪ 256 KB) is arena-backed.
- **Freeing thread-local heap across threads.** `combo.shutdown` (called by the CLI before the tracking
  allocator finalises) `pool_join`s first (workers dead, no longer touching their memos), then frees every
  worker's maps via a global mutex-guarded registry each worker appends to on first use — a heap `free` is not
  thread-affine, so the main thread can release a dead worker's backing. No-op when the pool never started.

Original analysis follows.

**Option A — reuse the map object across suits** (`clear_map` between calls):
```odin
// In analyse_ns (or annotate), create once:
memo := make(map[Suit_Layout]int)
defer delete(memo)
for suit in norn.Suit {
    d := suit_trick_distribution(north.suits[suit], south.suits[suit], &memo)
    clear(&memo)  // reset count, keep backing storage
    a.suits[suit] = d
}
```
`suit_trick_distribution` takes an optional `memo` parameter (nil → make/delete internally for
the standalone `dd_tricks` path). Across 8 suits the map's backing array is allocated once and
reused; capacity grows to the high-water mark of the largest suit's memo and stays there.
Reduces 8 alloc+free → 1 alloc + 7 clears + 1 free per deal.

Correctness: each suit's Suit_Layout space is independent (the four u16 values are holdings
for ONE suit, different suits can share rank positions numerically, so clearing between suits
is mandatory — which this does). The `dd_tricks` public proc (standalone path) creates its own
throwaway memo as today.

**Option B — put Phase 1 memos on temp allocator**:
`defer delete(memo)` on a temp-allocated map just marks the memory as freed in the arena,
which is effectively a no-op (arenas don't reclaim individual allocations). The map is then
recovered by `free_all` at end-of-deal. This works correctly but makes the `delete` call
misleading and wasted. Option A is cleaner.

### 8.3 Temp allocator usage and reset boundary

All temp allocations in one deal are freed by the single `free_all(context.temp_allocator)`
at the end of `annotate(.Html_Cards)`. This is the correct boundary — nothing temp-allocated
inside `annotate` is needed after it returns.

Current temp consumers per deal:
| Site | Allocation | Approx size |
|---|---|---|
| `gather_candidates` × 2 ptrnships | `[]Line_Result × 4 suits` | ~5 KB total |
| `opt_key` (if opt solver runs) | clone+sort worlds + string builder, × budget | variable |
| `opt_solver.memo` (map[string]Vec) | keys + 112-byte Vec values, × entries | variable |
| `opt_defender` groups+reduced | dynamic arrays per `assign_rec` leaf | small per leaf |
| `format_analysis` / `describe_suit_line` | string builders | < 1 KB |

After the §2 redundancy fix, `gather_candidates` is called 2× (one per partnership) instead
of 8×. The temp pressure from candidate slices drops from ~20 KB to ~5 KB per deal.

### 8.4 Batch-of-48 arena opportunity

The norn pipeline drives `annotate` serially (one deal at a time for scenarios with a
`Deal_Annotator`). The temp allocator already acts as a per-deal arena — `free_all` at end of
`annotate` is the reset. No additional arena is needed for the temp side.

The default allocator sees 8 map alloc+frees per deal = 384 per 48-deal batch. With Option A
(§8.2) this collapses to 2 per deal (one for NS, one for EW) = 96 per batch. If mimalloc is
enabled (`MIMALLOC_ENABLE` in sim.odin), the cost of small map allocs is already very low —
Option A's benefit is mainly avoiding repeated backing-array reallocation as the map grows, not
the allocator call overhead itself.

For a future scenario where `combo.annotate` is called from multiple threads (norn supports
parallel board generation), each thread must have its own `context.temp_allocator` (standard
Odin threading practice) and its own memo map. The memo is already private to the call stack;
thread safety requires no changes to combo itself.

### 8.5 Opt-solver temp accumulation

`opt_key` runs O(budget) times and each call:
1. `make([]Opt_World, n, context.temp_allocator)` — clone for sort
2. `strings.builder_make(context.temp_allocator)` — key serialization

Both are freed only by `free_all` at end-of-deal, not between opt calls. For suits where the
solver runs to budget (1.5M nodes), the temp accumulation for string keys can reach several MB.
In practice the solver falls back long before budget on most suits (many missing cards → early
overflow). But for short-suit / many-NS-cards cases that DO run deep, this is the largest temp
spike.

The §3.2 hash-key replacement eliminates the clone+sort+builder per opt_key call entirely,
replacing it with an inline hash computation over the already-sorted worlds. This also eliminates
the per-key temp allocation pressure.

### 8.6 No allocation in the hot Phase 2 evaluator

`sd_line_distribution` and `sd_trick` (the innermost fixed-line evaluator loop) are
**allocation-free**: all state is on the stack. `Suit_Layout` copies are 8 bytes passed by
value. `Sd_View` is a small struct passed by value. This is correct and should stay this way.
Any future memoization of `sd_trick` (§4.3) would introduce allocation — it must go on temp
and be cleared between `sd_line_distribution` calls to avoid cross-layout key collisions.

---

## 9. Threading

### 9.1 Across deals combo runs serially, and why (it parallelises WITHIN a deal — §9.4)

The norn CLI (`cli/run.odin`) exports scenarios on a thread pool — one worker per physical core,
one worker per scenario. Scenarios qualify for the pool only when `export_uses_dd` is false
(no `deal_filter` AND no `annotate` hook). Any scenario with a non-nil annotator is
**serialized** on the main thread, after the pool drains:

```
// cli/run.odin:150-151
export_uses_dd :: proc(job: ^Export_Task) -> bool {
    return job.deal_filter != nil || job.annotate != nil
}
```

`dd_and_combo_annotate` is registered as the annotator for `1major-game-force` and
`slam-makes-dd`. Even though combo itself needs no DDS, the combined annotator carries a non-nil
function pointer → `export_uses_dd = true` → the entire scenario serializes. Every one of the
48 deals in that scenario is then processed one at a time on the main thread.

Within each deal, `combo.annotate` itself is also fully sequential.

### 9.2 Thread-safety of combo internals

`g_binom` is written once at process start (`@(init)`) and thereafter read-only — safe to share
unsynchronised. The threading work (§9.4) added these package globals; all are either write-once-then-read
or accessed only under a mutex / by one thread at a time:
- `g_pool` / `g_pool_once` / `g_pool_started` — the pool + its lazy-init guard. `once_do` serialises init;
  after that the pool is used only by the single `annotate` caller (§9.1 gate), never concurrently.
- `g_scratch_regs` / `g_scratch_mutex` — the per-worker memo registry for `shutdown`; every append is under
  the mutex, and it is read only in `shutdown` after `pool_join` (workers dead).
- `tls_*` (thread-local): each worker's temp arena + two memo maps. Thread-local ⇒ never shared; a pointer to
  a worker's map is touched cross-thread only in `shutdown`, after the worker is joined.

Every other piece of mutable state is stack- or heap-local to the call (per-suit task outputs are by-value in
the caller's stack arrays; candidate slices / builders are caller- or temp-owned). There is **no shared mutable
state on the hot path**. Concurrent calls are safe provided each runs with its own allocators: the default
process-global temp arena is NOT safe to share, which is exactly why each worker sets `context.temp_allocator`
to its thread-local BSS arena (via `worker_scratch`) before calling combo procs.

### 9.3 Level 1 — decouple combo from the DD serialization gate

The simplest win: register a **combo-only** annotator separately from `dealsolve.annotate`:

```odin
// In sim.odin, instead of only registering dd_and_combo_annotate:
dd_annotators["1major-game-force"]    = dd_and_combo_annotate // DD + combo, stays serial (DD needs it)

// hypothetical: if a scenario doesn't need DD at all, combo alone is pool-eligible:
// (currently no such scenario, but the pattern would be):
// plain_annotators["some-scenario"]  = combo.annotate // no DD → pool-eligible
```

For the current two annotated scenarios both invoke `dealsolve.annotate` → they will always serialize
due to DDS global state. The level-1 opportunity only unlocks when a scenario uses combo without
DD (e.g. a future scenario whose annotation is the combo table only, with no DD filter). Worth
keeping in mind as scenarios are added: a combo-only annotator is pool-safe, a dd+combo
annotator is not.

If DDS were ever replaced with a reentrant solver, the serialization gate would disappear and
all scenarios (with or without annotators) would run concurrently on the pool — at which point
combo would automatically benefit at no cost.

### 9.4 Level 2 — parallelise within a single deal — SHIPPED (annotate 38 → 12.6 ms, 3.2×)

Three shipped stages; read §0 changes 6–8 for the numbers and the two premises measurement falsified.

**Stage 1 — coarse, per-deal fresh threads (change 6, 38 → 15 ms).** Four independent units — census
per partnership (`analyse_ns`) + SD bundle per partnership (gather + pick + SD total + make curve) — three
`thread.create`d per deal, the fourth run inline, then joined. 2.5×, below the ~3.7× ideal for 4 units.

**Stage 2 — persistent pool + zero-alloc scratch (change 7). Measured NEUTRAL, kept anyway.** A
process-lifetime `thread.Pool` (`init_pool` via `g_pool_once`) replaces per-deal `thread.create`, and each
worker's scratch moves to thread-local storage (heap memos + BSS temp arena, §8.2). This did NOT speed the
coarse path up (16.3 vs 15 ms — `thread.create` is cheap on Windows; spawn was never the ceiling). It ships
because it (a) enables stage 3, (b) removes per-batch spawn churn + steady-state heap allocs. Key mechanics
worth keeping in mind:
- **Completion is a `sync.Wait_Group`, not `pool_finish`.** `pool_finish`/`pool_join` SHUT THE POOL DOWN
  (they set `is_running=false` and join the threads) — unusable per deal. Each deal instead does
  `wait_group_add(N)`; every task calls `wait_group_done` on exit; the caller `wait_group_wait`s, then drains
  `pool_pop_done` so `tasks_done` doesn't grow across the batch. Safe because `annotate` is the pool's sole
  user and runs serially (§9.1) — exactly one deal's tasks are ever in flight.
- **Pool teardown** is `combo.shutdown` (CLI calls it before the tracking-allocator finalise): `pool_join`
  then free each worker's registered memos then `pool_destroy`. No-op if the pool never started.

**Stage 3 — fine-grained per-SUIT tasks (change 8, 16.3 → 12.6 ms, ratio → 3.2×).** The coarse wall-time is
bounded by the single longest unit — one SD bundle's four serial suit-gathers — so no coarse scheme beats it.
Splitting to the SUIT level makes the critical path ONE suit. Per deal: **16 independent tasks** — 8 census
suits (`Suit_Census_Task` → `suit_joint_table`) + 8 SD suit-gathers (`Suit_Sd_Task` → 5 `sd_line_joint_table`
per suit) — dispatched to the pool, then the caller assembles via the shared **`finish_census`/`finish_sd`**
seams (marginals + the joint DP + best-line pick). Each task writes its result BY VALUE (`Suit_Joint_Table` /
`[5]Line_Joint`, line names static literals) into a caller stack array — nothing points into a worker arena.
The serial and threaded paths call the *same* `finish_*` procs, so output is byte-identical
(`-define:COMBO_THREADS=false` is the parity gate — verified byte-for-byte incl. an n=48 second-seed batch).

Pool size = `min(physical cores, 16)` (`POOL_MAX_WORKERS` = the 16-task count). Each per-suit task runs on its
worker's thread-local memo (§8.2); the memos `clear()` on entry so per-suit dispatch is byte-identical to the
serial one-memo-per-4-suits reuse.

**Why 3.2× and not ~16× — MEASURED (`-define:COMBO_PROFILE=true`, `just bench`).** The per-deal cost splits into
three phases (cycle-counter probe in `annotate`, off by default, zero cost; `bench` prints the split):

| phase | % | ms/deal | note |
|---|---|---|---|
| PARALLEL (16 suit-tasks: dispatch + wait) | 55.6% | ~6.5 | wall time of the parallel phase |
| ASSEMBLE (`finish_census` ×2 + `finish_sd` ×2 — the two joint-DP `adaptive_curve_from`) | 44.0% | ~5.2 | **serial on the caller** |
| JSON (`write_*`) | 0.4% | ~0.04 | negligible — rule it out |

Two distinct problems, not one:
1. **ASSEMBLE (~5.2 ms) is serial on the main thread** — the two `adaptive_curve_from` joint DPs (14
   `dp_value_joint` passes each) run single-threaded after the barrier. Cleanly parallelisable. **FIXED (1A,
   shipped):** both `finish_sd` calls now dispatch to the pool (`Sd_Finish_Task`) while the caller runs the
   cheap `finish_census` pair; assemble measured **5.2 → 2.78 ms**, annotate **12.6 → ~9.1 ms**, parity byte-
   identical. New phase split: parallel 69% / 6.4 ms, assemble 30% / 2.78 ms, json 0.4%.
2. **The PARALLEL phase under-parallelises.** ~13 ms of task-work (8 census ≈ 1 ms + 8 SD ≈ 0.6 ms) finishes in
   ~6.4 ms wall — only ~2×, not ~16×. Cause: `core:thread.Pool` guards its task queue AND done-list with a
   SINGLE mutex; 16 workers + the caller contend on it every pop/append, so the lock (not compute) caps the
   phase. Task imbalance (heavy census vs light SD) compounds it. JSON is NOT the tail (measurement corrected
   the earlier guess). This is now the dominant term. **1B (merge to 8 census+SD tasks to cut mutex traffic)
   was tried and MEASURED SLOWER (9.1 → ~11 ms) — reverted:** coarsening removes the scheduler slack that hides
   the census/SD imbalance, and the mutex was not the real cap. Beating this needs a lock-lighter pool
   (per-worker queues / work-stealing), a bigger change with low batch-level payoff — deferred (§10).

### 9.5 Implementation order — DONE

The scalar fixes (§2 dedup, §4.3 memo, §8.2 reuse, §4.2 equiv-class) then the threading (§9.4 stages 1–3) are
all shipped: annotate 471 → 12.6 ms. What remains (§10) is second-order and profiled into a clear order —
**1A** parallelise the serial ASSEMBLE DPs (44%), then **1B** cut the `thread.Pool` mutex contention that caps
the parallel phase (merge to 8 census+SD tasks) — then `opt_key`/SIMD (neither on the annotate path).

The benchmark (`just bench`) provides the before/after numbers. The `bench_annotate` proc is
the single metric that captures all three layers (Phase 1, Phase 2, DP).

---

## 10. Summary — priority order

DONE (measured, byte-identical, tests green — see §0 for the running total, 471 → 83 ms):

| ✓ | What | Section | Measured |
|---|---|---|---|
| ✓ | §2 dedup: candidate lines evaluated once/partnership | §2 | 471 → 154 ms |
| ✓ | Phase-1 terminal-skip | §4.2 | ~3% |
| ✓ | Phase-2 `sd_trick` memo (`(layout, trick_no)` → u64, shared across splits) | §4.3 | p2 lines 1.7–2.5×; → 92 ms |
| ✓ | Option A map reuse (one scratch map, `clear()` per call) | §8.2 | 48 → 4 allocs/deal; → 83 ms |
| ✓ | Equivalence-class split enumeration (one representative per pattern, ∏ C(block,k) weight) | §4.2 | p1 8m 20×, p2 8m 30–42×; → 39 ms |
| ✓ | Intra-deal threading, coarse (4 units: census ×2, SD bundle ×2; per-deal fresh threads) | §9.4 | 2.5×; → 15 ms |
| ✓ | Persistent pool + per-worker zero-alloc scratch (PERF #1 coarse + #2) — memos heap+registry+`shutdown`, temp BSS | §8.2, §9.4 | coarse neutral (→ 16.3 ms); 0 allocs/deal, leak-clean |
| ✓ | Fine-grained per-SUIT tasks (16/deal: 8 census + 8 SD suits; shared `finish_census`/`finish_sd` assembly) | §9.4 | 16.3 → **12.6 ms**; ratio 2.5× → 3.2× |
| ✓ | **1A — parallelise ASSEMBLE.** Dispatch both partnership `finish_sd` (the two `adaptive_curve_from` joint DPs) as pool tasks (`Sd_Finish_Task`/`sd_finish_task`), run the cheap `finish_census` pair on the caller under them, join. | §9.4 | assemble 5.2 → **2.78 ms**; annotate 12.6 → **~9.1 ms** |

REMAINING (annotate is now ~9.1 ms). The serial ASSEMBLE tail is gone; the under-parallelised suit phase (69% /
~6.4 ms) is what's left — but the obvious lever (1B) was tried and BACKFIRED:

| Priority | What | Section | Result |
|---|---|---|---|
| ~~**1B**~~ | ~~Merge each suit's census+SD into 8 bigger tasks to halve pool-mutex traffic.~~ **TRIED → REVERTED (measured SLOWER: 9.1 → ~11 ms).** The premise was wrong: the single mutex was NOT the cap. Merging serialises census+SD within a task and destroys the scheduler slack that hides their imbalance (heavy census ~1 ms vs light SD ~0.6 ms) — 8 coarse tasks pack worse than 16 fine ones across the 12 physical cores. Parity held; it was simply slower on the bench (confirmed independent of worker count). Fine-grained 16-task split stands. | §9.4 | 9.1 → 11 ms ✗ |
| **1B′** | **The real remaining lever is the `thread.Pool` single queue+done mutex itself, not task count.** Would need a lock-lighter dispatch (per-worker queues / work-stealing, or lock-free done-list) — a bigger change than a task-granularity tweak, and low payoff (annotate runs on only 2 of 110 scenarios; ~5 ms × ~96 deals ≈ 0.5 s off the whole batch). Not worth it vs the combo feature gaps. | §9.4 | deferred |
| **2** | Replace `opt_key` string with inline sorted-hash `u64` (opt solver only, not in annotate path) | §3.2, §8.5 | removes O(budget) temp allocs when the opt search runs |
| **3** | SIMD `convolve` / batch splits through `sd_trick` (AVX2) | §5.1, §5.3 | small; revisit only if a profile says so |

Measure each with `just bench` (add `-define:COMBO_PROFILE=true` for the phase split). Gate on byte-identical
parity (`-define:COMBO_THREADS=false` diff) + 38 combo tests + no leaks after every step.

DONE since the last revision: PERF #1 (persistent pool) + #2 (zero-alloc scratch) shipped, and the
finer-task split that the old priority 1 gestured at (now stage 3, §9.4) — though measurement reframed
the win as *unit imbalance*, not spawn overhead. DROPPED: alpha-beta on the census + the trick-count
bound prune (change 5 removed the node explosion they targeted — §4.2); the batch-driver `mem.Arena`
for memos (superseded by per-worker thread-local heap memos + `shutdown`, §8.2).

The benchmark suite (§7) gates each change: measure before, apply, measure after. `bench_annotate`
is the single end-to-end metric.
