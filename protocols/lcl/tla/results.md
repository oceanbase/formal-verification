# TLC Model-Checking Results

TLC 2.14 (TLA+ Tools release 1.6.0, OpenJDK 26.0.1) checked all eight finite configurations with four workers. The [results index](completed-results.csv) records topology sizes, active exploration bounds, state counts, completion depths, and TLC fingerprint-collision estimates.

Every row below exhausted its finite state space completely (`exit 0`, TLC completion marker, no property violations, empty final queue). Symmetry reduction is not used because vertices carry distinct `PrID` / `AP` priorities under a strict total order.

## Completed Finite-Instance Checks

### Asynchronous Periodic Safety (`Spec`)

`Spec` drops round-count bounds to model immediate current-state edge updates under a global phase (`MaxLCLV`, `MaxPeriods`) without runtime knowledge of `AsgWidth(scc)` or `SccDiam(scc)` (Sections 4.6–4.7 and 7.1): proliferation and spread updates may fire in any order, repeat, or be omitted; proliferation may switch early to spread; `Stage 0` executes single-path local pre-proliferation walks; `Stage 3` runs inline on each incoming spread update; and victims abort without a global barrier.

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `MaxLCLV` | `MaxPeriods` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `AsyncAcyclicDAG.cfg` | Multi-outdegree diamond DAG (`N = 0` cycles) | 4 / 4 | Yes | 4 | 2 | 703 | 1,853 | 13 | 00s | Pass (exhausted) |
| `AsyncAnnulusTail.cfg` | High-AP annulus (`99 -> 80`) + cycle (`10 <-> 20`) + tail (`10 -> 90`) | 5 / 5 | Yes | 4 | 2 | 24,529 | 65,753 | 22 | 03s | Pass (exhausted) |
| `AsyncMultiCycleSCC.cfg` | Multi-cycle SCC (`5 <-> 15`, `20 -> 15 -> 10 -> 20`) + annulus (`50 -> 5`) | 5 / 6 | Yes | 3 | 2 | 108,887 | 304,650 | 29 | 19s | Pass (exhausted) |

### Round-Complete Deduction Safety (`RoundSpec`)

`RoundSpec` explores all single-pass edge-delivery permutations within each configured round (`ProlifRounds >= max(w, 1)` and `SpreadRounds >= 2d`), checking `AnnulusIsolation` (Lemma 5.10), `TopmostSCCUniqueVictim` (Theorem 5.11), and `PeriodBoundInvariant` (Theorem 5.12) alongside all general safety invariants.

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `ProlifRounds` | `SpreadRounds` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `RoundAnnulusTail.cfg` | High-AP annulus (`w = 2`) + cycle (`d = 1`) + tail (`90`) | 5 / 5 | Yes | 2 | 2 | 1,478 | 3,680 | 30 | 01s | Pass (exhausted) |
| `RoundMultiCycleSCC.cfg` | Figure 17(a) multi-cycle SCC (`w = 1, d = 3`) | 5 / 6 | No | 1 | 6 | 12,233 | 35,925 | 87 | 06s | Pass (exhausted) |
| `RoundHybridStage0.cfg` | Figure 6 local lasso (`60 -> 10 <-> 25`) + hybrid remote cycle | 6 / 6 | Yes | 1 | 4 | 6,288 | 18,637 | 42 | 04s | Pass (exhausted) |

### Multi-Period Liveness (`LiveSpec`)

| Config | Topology | `\|V\|` / `\|E\|` | `Stage0` | `ProlifRounds` | `SpreadRounds` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|:---:|---:|---:|---:|---:|---:|---:|---|
| `LivenessChained.cfg` | Figure 17(b) annulus (`95`) + surviving-bridge chained SCCs (`{30,40} -> {10,20}`) | 5 / 6 | Yes | 2 | 2 | 10,907 | 31,471 | 58 | 05s | Pass (exhausted) |
| `LivenessHybrid.cfg` | Figure 6 local lasso + hybrid remote cycle | 6 / 6 | Yes | 1 | 4 | 6,288 | 18,637 | 42 | 05s | Pass (exhausted) |

In `LivenessChained.cfg`, killing `40` in period 1 leaves the surviving bridge `95 -> 30 -> 10` (`w = 2`) into `{10, 20}`, so `30` enters period 2's annulus carrying its pumped `LCLV` from `{30, 40}` while not being a zero-indegree source.

### Checked Invariants and Temporal Properties

| Property | Spec Scope | Related Theorem / Lemma | Meaning |
|---|---|---|---|
| `TypeOK` | All | — | Type safety of all state variables, including distinctness of `dfsStack` |
| `TokenOriginValid` | All | Theorem 5.1a proof | Every vertex `x` holds a `PuID` `z >= x` from which `x` is reachable in `Edges` |
| `NoManslaughter` | All | Section 5.1.1 / Theorem 5.1a(a) | No never-deadlocked vertex outside cycles of `Edges` is ever detected or terminated |
| `ValidCycleVictim` | All | Theorem 5.1a(a) | Every detected or terminated vertex is the strict maximum-`AP` vertex of a simple cycle in `Edges` |
| `BoundedTotalVictims` | All | Section 5.1.1 / Theorem 5.1a(b) | Total detected or terminated vertices never exceed the number $N$ of simple cycles in `Edges` |
| `NoVictimKilledTwice` | All | — | Terminated vertices are never re-detected and retain no active incident edges |
| `LCLVMonotonic` | All | Section 7.1 | Every vertex's `LCLV` is nondecreasing across all transitions |
| `PuIDMonotonicInSpread` | All | Section 7.1 | Every vertex's `PuID` (`AP`) is nondecreasing throughout each `Spread` phase |
| `TopmostSCCExists` | All | Theorem 5.5 | Whenever a nontrivial SCC exists in `activeEdges`, at least one topmost SCC exists |
| `AnnulusIsolation` | `RoundSpec`, `LiveSpec` | Lemma 5.10(ii)–(iii) | Throughout `Spread` and `Detect`, `max(scc.LCLV) > 0` and `ASG(scc)` stays strictly below `scc` in `LCLV` |
| `TopmostSCCUniqueVictim` | `RoundSpec`, `LiveSpec` | Theorem 5.11 | At `Detect`, `detected ∩ USG(scc) = {max_AP(scc)}` for every topmost SCC |
| `PeriodBoundInvariant` | `RoundSpec`, `LiveSpec` | Theorem 5.12 | On cyclic graphs ($N \ge 1$), `period <= N` holds throughout execution |
| `EventuallyDeadlockFree` | `LiveSpec` | Section 5.1.2 / Theorem 5.12 | Every deadlock cycle is eventually broken (`<>[] (AllNontrivialSCCs(activeEdges) = {})`) |

## Manual Non-Vacuity (Ablation) Experiments

Single-line manual mutations of `LCL.tla` produce immediate TLC counterexamples (`TLC_WORKERS=1`):

| Manual Mutation in `LCL.tla` | Config | Result |
|---|---|---|
| Replace `SetMax(cycSet)` with `SetMax(SeqElems(dfsStack))` in `Stage0DetectLocalCycle` (`Algorithm 2` line 5) | `RoundHybridStage0` | Violates `NoManslaughter` at state 5: lasso stem `60` (`60 -> 10 <-> 25`) enters `detected` |
| Replace `pMap[v] = v` with `TRUE` in `DetectsOnEdge` | `RoundAnnulusTail` | Violates `ValidCycleVictim` at state 28: non-maximum cycle vertex `10` enters `detected` |
| Initialize `phase = "Spread"` in `Init` (skip Stage 1 Proliferation) | `RoundAnnulusTail` | Violates `AnnulusIsolation` at state 1 (and `TopmostSCCUniqueVictim` at `Detect`: upstream `99` masks `{10, 20}`) |
| Replace `LiveSpec == RoundSpec /\ Fairness` with `RoundSpec` | `LivenessChained` | Violates `EventuallyDeadlockFree` in a 20-state stuttering trace |

## Reachability Witnesses

Verified via `./check-witnesses.sh` with all base safety invariants kept active (`TLC` exits with code 12 on the negated witness invariant):

| Witness | Scenario Confirmed Reachable | Base Config | Result |
|---|---|---|---|
| `NoStage0LocalDetect` | `LCL+` Stage 0 detects local cycle victim `{25}` while sparing zero-indegree lasso stem `60` | `RoundHybridStage0` | `REACHED` (5 states) |
| `NoStage0RemotePush` | `LCL+` Stage 0 in period 1 pre-proliferates `LCLV` across `99 -> 80` into remote vertex `10` | `RoundAnnulusTail` | `REACHED` (4 states) |
| `NoAnnulusHighAPBlocked` | Upstream annulus (`99, 80`) stays unkilled and Stage 3 elects `detected ∩ USG(scc) = {20}` | `RoundAnnulusTail` | `REACHED` (28 states) |
| `NoDeadlockResolved` | Cycle `{10, 20}` resolves completely while annulus `99, 80` and downstream tail `90` remain unkilled | `RoundAnnulusTail` | `REACHED` (30 states) |
| `NoChainedMultiPeriod` | Chained SCCs with surviving pumped bridge `30 -> 10` resolve in period 2 (`40` then `20`, sparing `95`) | `LivenessChained` | `REACHED` (57 states) |
| `NoAsyncTwoVictimsInOneSCC` | Inline mid-spread abort on 2-cycle SCC (`5 <-> 15`, `20 -> 15 -> 10 -> 20`) kills `15` and then detects/aborts `20` in period 1 after `activeEdges` is already acyclic (still $\le N = 2$), whereas `RoundSpec`'s barrier elects only `20` in period 1 (leaving `5 <-> 15` for period 2) | `AsyncMultiCycleSCC` | `REACHED` (10 states) |

## Model Abstractions and Known Simplifications

- **Snapshot WFG and historical cycle soundness**: Under strict two-phase locking (Section 2.1), blocked transactions retain held locks until aborted; new transaction/edge arrivals during detection are not modeled. Under `Spec`'s inline mid-spread rollback without an end-of-spread barrier, an overlapping cycle's maximum can be detected via a token forwarded just before a neighbor's abort broke its cycle (`NoAsyncTwoVictimsInOneSCC`); `NoManslaughter` and `ValidCycleVictim` therefore hold with respect to the initial snapshot `Edges`.
- **Immediate current-state edge reads and global phase**: Like `Arbitration.tla`, edge actions read the sender's current `lclv` and `puid` under a shared `phase` rather than modeling an explicit wire queue with stale cross-period messages or per-server clock skew.
- **Single-pass per-round permutations in `RoundSpec`**: `pendingEdges` fires each active edge once per round in arbitrary order, whereas Definition 4.10 also allows repeated firings within a round (covered for safety by `Spec` and analytically via monotone bound $H$ in Lemma 5.10).
- **Single-branch Stage 0 path abstraction**: `Stage0*` explores one non-backtracking local path per started root rather than full multi-branch stack backtracking; completeness in `LiveSpec` rests on Stages 1–3.
