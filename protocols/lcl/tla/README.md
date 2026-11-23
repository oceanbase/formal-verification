# LCL and LCL+ TLA+ Specification

Executable TLA+ specification of OceanBase's Lock Chain Length (`LCL` and `LCL+`) distributed deadlock detection and resolution service across finite wait-for graphs (`WFG`). The module defines two execution models over the same state variables:

- **`Spec` (Asynchronous Periodic Safety Model, Sections 4.6–4.7, 5.1.1, and 7.1):** models immediate current-state edge updates under a global phase (`MaxLCLV`, `MaxPeriods`) without runtime knowledge of `AsgWidth(scc)` or `SccDiam(scc)`. Proliferation and spread updates may execute in any order, repeat, or be omitted; `Stage 0` runs single-path local pre-proliferation walks; `Stage 3` detection runs inline on each incoming spread update; and detected victims abort without a global cluster barrier.
- **`RoundSpec` and `LiveSpec` (Round-Complete Deduction Model, Algorithm 1 and Section 5):** explore all single-pass edge-delivery permutations per round on configured `ProlifRounds` and `SpreadRounds` bounds (with weak fairness `WF_vars` under `LiveSpec`) to verify annulus isolation (`Lemma 5.10`), unique victim selection per topmost SCC (`Theorem 5.11`), and $\le N$-period deadlock resolution (`Theorem 5.12`).

The model complements the standalone mathematical proof ([*Safety and Liveness of Lock Chain Length Deadlock Detection*](../proof/lcl-proof.pdf)), which establishes these guarantees for arbitrary finite wait-for graphs and arbitrary in-round edge multiplicities.

- Detailed results, ablations, and model abstractions: [`results.md`](results.md)
- Machine-readable 8-case summary: [`completed-results.csv`](completed-results.csv)

## Reproduce a check

From this directory, download and verify TLC 2.14 from the [TLA+ Tools 1.6.0 release](https://github.com/tlaplus/tlaplus/releases/tag/v1.6.0) (SHA-256 `71ce43150b6ee0a76cc33849ec45b2c6ae4323dc933b0acaef0928668ed0de72`) and run the round-deduction safety check, chained-SCC liveness check, and safety-checked reachability witnesses:

```sh
curl -fL https://github.com/tlaplus/tlaplus/releases/download/v1.6.0/tla2tools.jar -o tla2tools.jar && \
echo '71ce43150b6ee0a76cc33849ec45b2c6ae4323dc933b0acaef0928668ed0de72  tla2tools.jar' | shasum -a 256 -c - && \
TLC_WORKERS=4 TLC_HEAP=4g ./run.sh RoundAnnulusTail && \
TLC_WORKERS=4 TLC_HEAP=4g ./run.sh LivenessChained && \
./check-witnesses.sh
```

Each configuration run should finish with `Model checking completed. No error has been found.` Each witness in `./check-witnesses.sh` keeps all base safety invariants active and succeeds when TLC exits with code 12 on the negated witness invariant (`REACHED`). The runner passes `-deadlock` because terminal deadlock-free states (`phase = "Done"`) and finite period cutoffs are expected terminal states of the detector model.

## Files

| File | Purpose |
|---|---|
| [`LCL.tla`](LCL.tla) | Protocol actions (`Spec`, `RoundSpec`, `LiveSpec`), graph-theoretic operators, safety/liveness properties, and witnesses |
| [`MC.tla`](MC.tla) | Concrete multi-server `WFG` benchmark topologies (`Diamond`, `AnnulusTail`, `MultiCycle`, `Hybrid`, `Chained`) |
| [`AsyncAcyclicDAG.cfg`](AsyncAcyclicDAG.cfg) | `Spec` safety check on acyclic multi-outdegree diamond DAG (`N = 0` cycles) |
| [`AsyncAnnulusTail.cfg`](AsyncAnnulusTail.cfg) | `Spec` safety check with high-priority annulus chain (`99 -> 80`), cycle (`10 <-> 20`), and downstream tail (`10 -> 90`) |
| [`AsyncMultiCycleSCC.cfg`](AsyncMultiCycleSCC.cfg) | `Spec` safety check on multi-cycle SCC (`5 <-> 15` and `20 -> 15 -> 10 -> 20`) with upstream annulus |
| [`RoundAnnulusTail.cfg`](RoundAnnulusTail.cfg) | `RoundSpec` check of Lemma 5.10 and Theorem 5.11 on high-priority annulus + downstream tail (`w = 2, d = 1`) |
| [`RoundMultiCycleSCC.cfg`](RoundMultiCycleSCC.cfg) | `RoundSpec` check of Theorem 5.11 unique victim on Figure 17(a) multi-cycle SCC (`w = 1, d = 3`) |
| [`RoundHybridStage0.cfg`](RoundHybridStage0.cfg) | `RoundSpec` check of `LCL+` Stage 0 local lasso resolution + distributed cycle resolution (Figure 6) |
| [`LivenessChained.cfg`](LivenessChained.cfg) | `LiveSpec` two-period liveness check on Figure 17(b) chained SCCs with surviving pumped bridge (`95 -> {30 <-> 40} -> {10 <-> 20}`) |
| [`LivenessHybrid.cfg`](LivenessHybrid.cfg) | `LiveSpec` liveness check on hybrid local lasso + distributed cycle |
| [`completed-results.csv`](completed-results.csv) | Machine-readable summary of all 8 completed exhaustive runs |
| [`run.sh`](run.sh) | Run one configuration: `[TLC_WORKERS=4] [TLC_HEAP=4g] ./run.sh <Config>` |
| [`check-witnesses.sh`](check-witnesses.sh) | Verify safety-checked reachability witnesses (each outputs `REACHED`) |

## Paper-to-Model Mapping

Names follow Sections 3–5 of the TOCS paper:

| Paper (Sections 3–5) | TLA+ Model (`LCL.tla`) |
|---|---|
| Wait-for edge $A(\neq B) \to B$ (Def. 3.1) | `Edges`, `activeEdges` |
| Walk reachability $A \Rightarrow B$ & two-way $A \Leftrightarrow B$ (Defs. 3.2–3.3) | `Reachable(E, u)`, `ProperReachable(E, u)`, `TwoWay(E, u, v)` |
| Nontrivial SCC, `USG(scc)`, `ASG(scc)` (Defs. 3.6–3.7) | `AllNontrivialSCCs(E)`, `USG(E, scc)`, `ASG(E, scc)` |
| Topmost SCC (Defs. 5.2–5.3) | `IsTopmostSCC(E, scc)`, `TopmostSCCs(E)` |
| `PrID`, `AP`, `PuID`, `LCLV` (Defs. 4.1–4.4) | Vertex integer (`PrID = AP`), `puid[v]`, `lclv[v]` |
| `Stage 0: LCL+ Pre-proliferation` (Sec. 4.7, Alg. 2) | `Stage0Start`, `Stage0DetectLocalCycle`, `Stage0AdvanceLocal`, `Stage0PushRemote` |
| `Stage 1: LCL Proliferation` (Def. 4.8, Alg. 1) | `AsyncProlifEdge` (`Spec`), `RoundProlifEdge` & `AdvanceProlifRound` (`RoundSpec`) |
| `Stage 2: LCL Spread` & Formula (1) (Def. 4.9, Alg. 1) | `SpreadLCLV`, `SpreadPuID`, `AsyncSpreadEdge`, `RoundSpreadEdge` |
| `Stage 3: LCL Detection` & victim rollback (Sec. 4.5) | `DetectsOnEdge`, `AsyncAbortVictim`, `ResolvePeriod` |

## Theorem-to-Property Mapping

For `RoundSpec` and `LiveSpec`, the listed configurations supply constant `ProlifRounds` and `SpreadRounds` satisfying the round hypotheses of Lemma 5.10 and Theorem 5.11 across all initial and residual topologies.

| Paper / Companion Proof | Checked TLA+ Properties |
|---|---|
| Section 5.1.1 / Theorem 5.1a(a) Historical soundness (no manslaughter) | `NoManslaughter`, `ValidCycleVictim`, `TokenOriginValid` |
| Section 5.1.1 / Theorem 5.1a(b) Per-cycle victim bound ($\le N$ victims) | `BoundedTotalVictims`, `NoVictimKilledTwice` |
| Section 7.1 Monotonicity within period | `LCLVMonotonic`, `PuIDMonotonicInSpread` |
| Theorem 5.5 Topmost SCC existence | `TopmostSCCExists` |
| Lemma 5.10(ii)–(iii) Annulus isolation | `AnnulusIsolation` (under configured `RoundSpec` / `LiveSpec`) |
| Theorem 5.11 Unique victim in topmost SCC | `TopmostSCCUniqueVictim` (under configured `RoundSpec` / `LiveSpec`) |
| Section 5.1.2 / Theorem 5.12 $\le N$-period liveness | `PeriodBoundInvariant`, `EventuallyDeadlockFree` (under configured `LiveSpec`) |
