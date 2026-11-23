# TLC Model-Checking Results

TLC 2.14 (TLA+ Tools release 1.6.0, OpenJDK 26.0.1) checked all eight finite configurations with four workers. The [results index](completed-results.csv) records topology sizes, bounds, state counts, completion depths, and TLC fingerprint-collision estimates.

Every row below exhausted its finite state space completely (`exit 0`, TLC completion marker, no property violations, empty final queue). Symmetry reduction is not used because vertices carry distinct `PrID` / `AP` priorities under a total order.

## Completed Finite-Instance Checks

### Asynchronous Periodic Safety (`Spec`)

`Spec` drops round-count bounds to mirror OceanBase's fixed-period timer implementation (Sections 4.6–4.7 and 7.1): proliferation and spread messages may fire in any order or be lost, proliferation may switch early to spread without knowing `AsgWidth(scc)`, `Stage 0` executes local DFS pre-proliferation, `Stage 3` runs inline during spread, and victims abort without a global barrier.

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `MaxLCLV` | `MaxPeriods` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `AsyncAcyclicDAG.cfg` | Multi-outdegree diamond DAG (`N = 0` cycles) | 4 / 4 | Yes | 4 | 2 | 703 | 1,853 | 15 | 00s | Pass (exhausted) |
| `AsyncAnnulusTail.cfg` | High-AP annulus (`99 -> 80`) + cycle (`10 <-> 20`) + tail (`10 -> 90`) | 5 / 5 | Yes | 4 | 2 | 24,529 | 65,753 | 22 | 01s | Pass (exhausted) |
| `AsyncMultiCycleSCC.cfg` | Multi-cycle SCC (`5 <-> 15`, `20 -> 15 -> 10 -> 20`) + annulus (`50 -> 5`) | 5 / 6 | Yes | 3 | 2 | 108,887 | 304,650 | 29 | 15s | Pass (exhausted) |

### Round-Complete Deduction Safety (`RoundSpec`)

`RoundSpec` enforces Definition 4.10's per-round edge coverage across all asynchronous edge-delivery permutations within each round (`ProlifRounds >= max(w, 1)` and `SpreadRounds >= 2d`), checking `AnnulusIsolation` (Lemma 5.10) and `TopmostSCCUniqueVictim` (Theorem 5.11) in addition to all general safety invariants.

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `ProlifRounds` | `SpreadRounds` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `RoundAnnulusTail.cfg` | High-AP annulus (`w = 2`) + cycle (`d = 1`) + tail (`90`) | 5 / 5 | Yes | 2 | 2 | 1,478 | 3,680 | 30 | 00s | Pass (exhausted) |
| `RoundMultiCycleSCC.cfg` | Figure 17(a) multi-cycle SCC (`w = 1, d = 3`) | 5 / 6 | No | 1 | 6 | 12,233 | 35,925 | 87 | 03s | Pass (exhausted) |
| `RoundHybridStage0.cfg` | Figure 6 local lasso (`60 -> 10 <-> 25`) + hybrid remote cycle | 6 / 6 | Yes | 1 | 4 | 6,288 | 18,637 | 42 | 02s | Pass (exhausted) |

### Multi-Period Liveness (`LiveSpec`)

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `ProlifRounds` | `SpreadRounds` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `LivenessChained.cfg` | Figure 17(b) annulus (`95`) + chained SCCs (`{30,40} -> {10,20}`) | 5 / 6 | Yes | 1 | 2 | 4,466 | 13,031 | 43 | 02s | Pass (exhausted) |
| `LivenessHybrid.cfg` | Figure 6 local lasso + hybrid remote cycle | 6 / 6 | Yes | 1 | 4 | 6,288 | 18,637 | 42 | 03s | Pass (exhausted) |

### Checked Invariants and Temporal Properties

| Property | Spec Scope | Related Theorem / Lemma | Meaning |
|---|---|---|---|
| `TypeOK` | All | — | Type safety of all state variables |
| `TokenOriginValid` | All | Theorem 5.1 proof | Every vertex `x` holds a `PuID` `z >= x` from which `x` is reachable in `Edges` |
| `NoManslaughter` | All | Section 5.1.1 / Theorem 5.1(a) | No vertex outside a directed cycle in `Edges` is ever detected or terminated |
| `ValidCycleVictim` | All | Theorem 5.1(a) | Every detected or terminated vertex is the strict maximum-`AP` vertex of a simple cycle in `Edges` |
| `BoundedTotalVictims` | All | Section 5.1.1 / Theorem 5.1(b) | Total terminated vertices never exceed the number $N$ of simple cycles in `Edges` |
| `NoVictimKilledTwice` | All | — | Terminated vertices are never re-detected and retain no active incident edges |
| `LCLVMonotonic` | All | Section 7.1 | Every vertex's `LCLV` is nondecreasing across all transitions |
| `PuIDMonotonicInSpread` | All | Section 7.1 | Every vertex's `PuID` (`AP`) is nondecreasing throughout each `Spread` phase |
| `TopmostSCCExists` | All | Theorem 5.5 | Whenever a nontrivial SCC exists in `activeEdges`, at least one topmost SCC exists |
| `AnnulusIsolation` | `RoundSpec`, `LiveSpec` | Lemma 5.10(ii)–(iii) | Throughout `Spread` and `Detect`, `ASG(scc)` vertices stay strictly below `scc` in `LCLV` |
| `TopmostSCCUniqueVictim` | `RoundSpec`, `LiveSpec` | Theorem 5.11 | At `Detect`, `detected ∩ USG(scc) = {max_AP(scc)}` for every topmost SCC |
| `EventuallyDeadlockFree` | `LiveSpec` | Section 5.1.2 / Theorem 5.12 | Every deadlock cycle is eventually broken (`<>[] (AllNontrivialSCCs(activeEdges) = {})`) |

## Non-Vacuity (Ablation) Checks

Mutating key protocol rules produces immediate TLC counterexamples:

| Mutation | Config | Result |
|---|---|---|
| Select Stage 0 victim from entire `dfsStack` instead of cycle suffix (`Algorithm 2` line 5) | `RoundHybridStage0` | Violates `NoManslaughter` in 5 states: lasso stem `60` (`60 -> 10 <-> 25`) is falsely killed |
| Omit `puid[v] = v` check in Stage 3 detection (`DetectsOnEdge`) | `RoundAnnulusTail` | Violates `ValidCycleVictim` in 28 states: non-maximum and downstream vertices trigger false detection |
| Skip Stage 1 Proliferation (start directly in `Spread`) | `RoundAnnulusTail` | Violates `AnnulusIsolation` at state 1 (and `TopmostSCCUniqueVictim` at `Detect`: upstream `99` masks `{10, 20}`) |
| Remove `Fairness` from `LiveSpec` | `LivenessChained` | Violates `EventuallyDeadlockFree` in 20 states (stuttering before resolving downstream SCC) |

## Reachability Witnesses

Verified via `./check-witnesses.sh`; each invariant asserts that a target scenario is unreachable, so TLC's violation (`REACHED`) confirms the execution path exists:

| Witness | Scenario Confirmed Reachable | Base Config | Result |
|---|---|---|---|
| `NoStage0LocalDetect` | `LCL+` Stage 0 immediately detects local cycle `{10, 25}` while sparing upstream stem `60` | `RoundHybridStage0` | `REACHED` (5 states) |
| `NoStage0RemotePush` | `LCL+` Stage 0 pre-proliferates `LCLV` across local chain `99 -> 80` into remote vertex `10` | `RoundAnnulusTail` | `REACHED` (4 states) |
| `NoAnnulusHighAPBlocked` | Upstream annulus chain (`AP = 99, 80`) is isolated by `LCLV`, allowing cycle `{10, 20}` to elect `20` | `RoundAnnulusTail` | `REACHED` (29 states) |
| `NoDeadlockResolved` | Distributed cycle resolves while multi-outdegree downstream neighbor `90` remains untouched | `RoundAnnulusTail` | `REACHED` (30 states) |
| `NoChainedMultiPeriod` | Chained SCCs (`{30, 40} -> {10, 20}`) resolve across two periods (`40` then `20`) | `LivenessChained` | `REACHED` (42 states) |
| `NoAsyncTwoVictimsInOneSCC` | Inline mid-spread abort on 2-cycle SCC (`5 <-> 15`, `20 -> 15 -> 10 -> 20`) kills both `15` and `20` ($\le N = 2$), whereas `RoundSpec` kills only `20` | `AsyncMultiCycleSCC` | `REACHED` (10 states) |

## Model Abstractions and Known Simplifications

- **Static initial wait-for snapshot with dynamic victim removal**: Under strict two-phase locking (Section 2.1), blocked transactions hold their locks until aborted, so cycle edges remain stable until a victim terminates. Dynamic arrival of new transactions during an active period is outside the bounded snapshot model; `MaxLCLV` and `MaxPeriods` bound asynchronous `Spec` exploration.
- **Period reset synchronization**: Following Section 4.6 and Section 5, `PuID` resets to `PrID` at period boundaries. Per-server clock skew across period resets is not modeled.
- **Stage 0 DFS stack**: `Stage0Start` initiates one active local DFS walk at a time (`RoundSpec` from zero-indegree sources as in Algorithm 2 line 1; `Spec` from any active vertex to cover on-demand lock-wait triggers).
- **Transaction-granularity WFG**: Models OceanBase's production transaction-granularity WFG (Section 4.8, Figure 7(c)) rather than task-granularity intermediate nodes.
