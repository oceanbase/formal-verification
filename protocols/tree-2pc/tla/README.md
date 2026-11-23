# Tree-Structured 2PC TLA+ Specification

Dynamic tree-structured two-phase commit (2PC) specification over OceanBase coalesced log streams (`src/storage/tx`). The model covers multi-level log-stream coordination, phase-bounded participant-set merging (`parts`, `incr`, `interm`), lock-synchronized non-atomic partition transfers (`BeginTransfer`, `CommitTransferLogs`, `FinishTransfer` under `lock_t` / `blocked`), circular transaction topologies (`Handle2pcDuplicatePrepareRequest`), context reclamation (`ForgetCtx` to `TOMBSTONE`), Transaction Data Table (TDT) retention and eviction, and coordinator retries with `prepare_unknown` and `trans_unknown`.

The model exercises the concrete mechanisms of *A Tree-Structured Two-Phase Commit Framework for OceanBase: Optimizing Scalability and Consistency* (PVLDB 19(12), DOI: `10.14778/3827998.3828030`) and complements the companion protocol-model proof ([*Safety and Liveness of a Tree-Structured Two-Phase Commit Protocol Model*](../proof/tree-2pc-proof.pdf)). The checked properties describe the TLA+ model under the finite bounds listed below.

- Detailed results, ablations, and model abstractions: [`results.md`](results.md)
- Machine-readable 10-case summary: [`completed-results.csv`](completed-results.csv)

## Reproduce a check

From this directory, download the TLC 2.14 executable ([TLA+ Tools 1.6.0 release](https://github.com/tlaplus/tlaplus/releases/tag/v1.6.0), SHA-256 `71ce43150b6ee0a76cc33849ec45b2c6ae4323dc933b0acaef0928668ed0de72`) and run the base transfer safety and liveness checks:

```sh
curl -fL https://github.com/tlaplus/tlaplus/releases/download/v1.6.0/tla2tools.jar -o tla2tools.jar
TLC_WORKERS=4 TLC_HEAP=2g ./run.sh Tree2PCTransfer
TLC_WORKERS=4 TLC_HEAP=2g ./run.sh LivenessCircular
```

TLC should finish with “Model checking completed. No error has been found.” Reachability witnesses can be verified independently:

```sh
TLC_WORKERS=4 TLC_HEAP=2g ./check-witnesses.sh
BASE=CoverageCircular TLC_WORKERS=4 TLC_HEAP=2g ./check-witnesses.sh NoCircularPrepare
BASE=LiveCoverage TLC_WORKERS=4 TLC_HEAP=2g ./check-witnesses.sh NoLiveCircularCommit
```

Each witness succeeds when its output says `REACHED`. Its invariant asserts that the target scenario is unreachable, so a counterexample trace confirms reachability. The runner passes `-deadlock` because terminal states (`TOMBSTONE`, `DONE`) are expected once a transaction completes.

## Files

| File | Purpose |
|---|---|
| `Tree2PC.tla` | Complete specification (`Spec`, `LiveSpec`), safety invariants, monotonicity and liveness properties, and coverage witnesses |
| `Tree2PCTransfer.cfg` | 3-stream dynamic transfer safety check (`r -> {a}` + fresh `d1`, `MaxTransfers = 1`, context loss + TDT + retry) |
| `Tree2PCCircular.cfg` | 3-stream circular topology safety check (`r -> a -> b`, `MaxTransfers = 1`, context loss + TDT + retry) |
| `Tree2PCMultiHop.cfg` | 4-stream multi-hop chain transfer safety check (`r -> {a}` + fresh `{d1, d2}`, `MaxTransfers = 2`, context loss + TDT + retry) |
| `Tree2PCStatic.cfg` | 4-stream 2-level hierarchical safety check (`r -> {a, b}`, `a -> {c}`, `MaxTransfers = 0`, context loss + TDT + retry) |
| `Tree2PCDiamond.cfg` | 4-stream 2-partition cross-branch / diamond transfer safety check (`r -> {a, b}` + fresh `d1`, `MaxTransfers = 2`) |
| `Tree2PCHierTransfer.cfg` | 5-stream hierarchical + fresh transfer stream safety check (`r -> {a, b}`, `a -> {c}` + `d1`, 3 partitions, `MaxTransfers = 1`, full TDT + retry) |
| `LivenessTransfer.cfg` | 3-stream dynamic transfer + retry liveness check (no symmetry) |
| `LivenessCircular.cfg` | 3-stream circular transfer + context loss + TDT + retry liveness check (no symmetry) |
| `LivenessMultiHop.cfg` | 4-stream multi-hop transfer liveness check (`MaxTransfers = 2`, no symmetry) |
| `LivenessDiamond.cfg` | 4-stream 2-partition cross-branch / diamond transfer liveness check (`MaxTransfers = 2`, no symmetry) |
| `Coverage.cfg`, `CoverageCircular.cfg`, `LiveCoverage.cfg` | Shared base configurations for reachability witnesses |
| `completed-results.csv` | Machine-readable table of all 10 completed exhaustive runs |
| `run.sh` | Run a config: `[TLC_WORKERS=8] [TLC_HEAP=8g] [TLC_DIRECT=16g] ./run.sh <Config>` |
| `check-witnesses.sh` | Run reachability witnesses (each should output `REACHED`); override base via `BASE=CoverageCircular` or `BASE=LiveCoverage` |

### Requirements

- Java 8 or newer on `PATH`, or set `JAVA` to the desired Java executable.
- Place TLC 2.14 at `tla2tools.jar` in this directory or set `TLA2TOOLS` to an absolute path to the jar.

## Paper-to-Model Mapping

Names follow Sections 2–6 and Algorithms 1–3 of the paper:

| Paper (Sections 2–6) | TLA+ Model |
|---|---|
| Log stream participant | `u \in LS`, with root coordinator `Root` and initially uninvolved streams `IdleLS` |
| Transaction Context Table (TCT) state | `state[u] \in {"IDLE", "RUNNING", "PREPARE", "COMMIT", "ABORT", "TOMBSTONE"}` |
| SQL / incremental / intermediate participants (§4.2) | `parts[u]`, `incr[u]`, `interm[u]`, with active phase children `Children(u) = parts[u] \cup incr[u]` |
| Phase-boundary `COMMITLOGS` / `LogCommit` (Alg. 1 & 3) | `ApplyMerge(n)` guarded by `~blocked[n]` when persisting `PREPARE`, `COMMIT`, or `ABORT` |
| Partition transfer & `MigrateData` (Alg. 1 & 2, §4.3) | `BeginTransfer(p, dst)` -> `CommitTransferLogs` -> `FinishTransfer`, updating `host[p]`, `blocked[src]`, and `interm[src]` |
| Recorded first preparing parent | `parent[n]`, inducing the acyclic first-parent arborescence `FirstParentAcyclic` |
| Circular duplicate `PREPARE` rule (§4.6) | `Handle2pcDuplicatePrepareRequest(n)` (`m.src # parent[n]` replies `"ok"` once local `PREPARE` persists) |
| Context reclamation (`clear_log` / `ForgetCtx`) | `ForgetCtx(n)` transitions `COMMIT`/`ABORT` to `TOMBSTONE` once `AllAcked(n)` holds |
| Transaction Data Table (TDT) & retention expiry (§5.3) | `tdt[n] \in {"none", "COMMIT", "ABORT"}` and `EvictTDT(n)` |
| `prepare_unknown` & `trans_unknown` (§5.2) | `"prep_unknown"` in `HandleOrphan2pcPrepareRequest` / `ProbeParticipant`; `"ABORT"` on newly created `Root` vs. `"TRANS_UNKNOWN"` in `ResolveRetry` |

### Parameter Semantics

- **`MaxTransfers`**: bounds the total number of dynamic partition migrations (`0`, `1`, or `2`). Even `MaxTransfers = 1` exercises transfers overlapping `RUNNING`, `PREPARE`, and `COMMIT` (`trans_1`, `trans_2`, `trans_3` of Algorithm 1) as well as cyclic back-edges (`b -> a`, `b -> r`); `MaxTransfers = 2` covers multi-hop chains (`a -> d1 -> d2`) and diamond convergence (`a -> d1`, `b -> d1`).
- **`AllowContextLoss`, `AllowTDTEvict`, `AllowRetry`**: enable volatile `RUNNING` context loss before `PREPARE` (newly created coordinator `prepare_unknown -> ABORT`), TDT retention expiry after `TOMBSTONE`, and lost client replies with recreated-coordinator probing (`TDT hit -> COMMIT/ABORT`, `TDT miss -> TRANS_UNKNOWN`).

### Theorem-to-Property Mapping

| Paper / Companion Proof | Checked TLA+ Properties |
|---|---|
| Theorem 2.2 Minimum participant set (Lemma A.2) | `MinParticipantSet` |
| Theorems 4.1 & 4.3 Transfer principle & `lock_t` concurrency (Lemma A.1) | `TransferPrinciple` and `MinParticipantSet` |
| Section 4.6 Circular prepare soundness (Lemmas A.3 & A.4) | `FirstParentAcyclic` and `CommitRequiresAllPrepared` |
| Theorem 6.1 Safety — Agreement & stability | `Agreement`, `DecisionStable`, and `StateMonotonic` |
| Section 5.2–5.3 Unknown-state retry non-fabrication (Lemma A.5) | `ClientReplyConsistent` and `NoUnknownWhenTDTRetained` |
| Theorem 6.2 Liveness (including circular topologies) | `EventuallyAllDecide`, `EventuallyAllTombstone`, and `ClientEventuallyResolved` under `LiveSpec` |
