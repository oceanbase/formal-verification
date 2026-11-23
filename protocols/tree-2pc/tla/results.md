# TLC Model-Checking Results

TLC 2.14 (TLA+ Tools release 1.6.0, OpenJDK 26.0.1) checked all ten finite configurations (six safety and four liveness) with eight workers. The [results index](completed-results.csv) records the model bounds, state counts, wall times, and TLC fingerprint-collision estimates.

This specification models OceanBase's dynamic tree-structured two-phase commit protocol over coalesced log streams (`src/storage/tx`): phase-bounded participant sets (`parts`, `incr`, `interm`), lock-synchronized non-atomic partition transfers (`BeginTransfer`, `CommitTransferLogs`, `FinishTransfer` under `lock_t` / `blocked`), non-blocking duplicate `PrepareReq` responses on circular topologies, and post-reclamation retry handling via the Transaction Context Table (TCT), Transaction Data Table (TDT), `prepare_unknown`, and `trans_unknown`. It complements the companion protocol-model proof ([*Safety and Liveness of a Tree-Structured Two-Phase Commit Protocol Model*](../proof/tree-2pc-proof.pdf)). Every row in the tables below exhausted its finite state space completely (`exit 0`, TLC completion marker, no errors, empty final queue). Reported depth is the completion depth reported by TLC, not a configured depth cutoff.

## Completed Finite-Instance Checks

### Safety (with leaf/idle symmetry `Permutations(HostedDirectLeaf) \cup Permutations(UninitDirectLeaf) \cup Permutations(HostedSubLeaf) \cup Permutations(UninitSubLeaf) \cup Permutations(IdleLS)`)

| Config | Initial Layout | Streams | Partitions | `MaxTransfers` | Context Loss & TDT/Retry | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|---:|---:|:---:|---:|---:|---:|---:|---|
| `Tree2PCTransfer.cfg` | `r -> {a}` + idle `{d1}` | 3 | 1 | 1 | Yes | 5,345 | 13,512 | 28 | < 01s | Pass (exhausted) |
| `Tree2PCCircular.cfg` | `r -> a -> b` (cyclic under transfer) | 3 | 2 | 1 | Yes | 68,803 | 217,710 | 34 | 01s | Pass (exhausted) |
| `Tree2PCMultiHop.cfg` | `r -> {a}` + idle `{d1, d2}` | 4 | 1 | 2 | Yes | 140,287 | 457,698 | 39 | 02s | Pass (exhausted) |
| `Tree2PCStatic.cfg` | `r -> {a, b}`, `a -> {c}` | 4 | 3 | 0 | Yes | 227,637 | 883,911 | 36 | 04s | Pass (exhausted) |
| `Tree2PCDiamond.cfg` | `r -> {a, b}` + idle `{d1}` | 4 | 2 | 2 | No | 2,120,256 | 9,505,771 | 36 | 28s | Pass (exhausted) |
| `Tree2PCHierTransfer.cfg` | `r -> {a, b}`, `a -> {c}` + idle `{d1}` | 5 | 3 | 1 | Yes | 42,754,064 | 200,630,760 | 48 | 14m 25s | Pass (exhausted) |

**Fingerprint collision estimates**: TLC uses 64-bit state fingerprints. Across the six safety runs, reported tool estimates (recorded verbatim in [`completed-results.csv`](completed-results.csv)) range from `2.4E-12` (`Tree2PCTransfer.cfg`) to `3.7E-4` optimistic / `1.3E-4` actual (`Tree2PCHierTransfer.cfg`); these are probabilistic tool estimates rather than observed collisions.

**Checked safety invariants and properties (8 invariants + 2 monotonicity properties)**:

| Property | Related theorem or lemma | Meaning |
|---|---|---|
| `TypeOK` | — | Complete type safety of all TCT, TDT, transfer (`inFlightXfer`), message, and retry (`retryVotes`) variables |
| `Agreement` | Theorem 6.1(a) | No two log streams ever record conflicting terminal outcomes (`COMMIT` vs. `ABORT`), and active/TDT decisions agree with durable history |
| `CommitRequiresAllPrepared` | Lemma A.4 | Whenever any stream commits, no stream remains in `RUNNING` or `ABORT`, and every active stream holds `PREPARE`, `COMMIT`, or post-`COMMIT` `TOMBSTONE` |
| `FirstParentAcyclic` | Lemma A.3 | Prior to any `COMMIT` decision, every stream that entered `PREPARE` from `RUNNING` traces back to `Root` along acyclic first-parent pointers, even when `Children` contains cycles |
| `TransferPrinciple` | Theorems 4.1 & 4.3 (Lemmas A.1 & A.2) | Every partition host is active, and outside the commit window between `CommitTransferLogs` and `FinishTransfer`, every active stream either lies in the `Root`-rooted `parts \cup incr \cup interm` graph or holds a terminal decision |
| `MinParticipantSet` | Theorem 2.2 & Theorem 6.1(b) (Lemma A.2) | Outside the transfer commit window, every partition host lies in the `Root`-rooted commit graph or has already migrated a terminal decision; decided hosts always match `Root`; once all streams reach `TOMBSTONE`, every final partition host holds `Root`'s decision |
| `ClientReplyConsistent` | Section 5.2 (Lemma A.5 / Theorem 6.1(c)) | Client responses never fabricate `COMMIT` without a committed root decision or `ABORT` without an aborted root decision; `TRANS_UNKNOWN` arises only on a recreated coordinator after `Root` reaches `TOMBSTONE` and evicts its TDT entry |
| `NoUnknownWhenTDTRetained` | Section 5.3 (Lemma A.5) | While TDT retains terminal decisions on decided streams, client retries never surface `TRANS_UNKNOWN` |
| `DecisionStable` | Theorem 6.1(a) | Once a log stream records `COMMIT` or `ABORT`, its terminal outcome never changes |
| `StateMonotonic` | — | Each stream's 2PC lifecycle rank (`IDLE < RUNNING < PREPARE < COMMIT/ABORT < TOMBSTONE`) is nondecreasing |

### Liveness (`LiveSpec`, no symmetry)

| Config | Initial Layout | Streams | Partitions | `MaxTransfers` | Context Loss & TDT/Retry | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|---:|---:|:---:|---:|---:|---:|---:|---|
| `LivenessTransfer.cfg` | `r -> {a}` + idle `{d1}` | 3 | 1 | 1 | Yes | 5,345 | 13,512 | 28 | < 01s | Pass (exhausted) |
| `LivenessMultiHop.cfg` | `r -> {a}` + idle `{d1, d2}` | 4 | 1 | 2 | No | 50,073 | 158,690 | 29 | 02s | Pass (exhausted) |
| `LivenessCircular.cfg` | `r -> a -> b` (cyclic under transfer) | 3 | 2 | 1 | Yes | 68,803 | 217,710 | 34 | 03s | Pass (exhausted) |
| `LivenessDiamond.cfg` | `r -> {a, b}` + idle `{d1}` | 4 | 2 | 2 | No | 4,239,402 | 19,007,679 | 36 | 04m 52s | Pass (exhausted) |

Symmetry reduction is disabled because TLC liveness checking is unsound under symmetry.

**Checked liveness properties (Theorem 6.2 & Section 5)**:
- `EventuallyAllDecide`: eventually `Root`, every active log stream, and every partition's final host reach a common terminal `COMMIT` or `ABORT` outcome and retain it forever.
- `EventuallyAllTombstone`: eventually every active log stream collects all child acknowledgments and reclaims its TCT (`TOMBSTONE`), confirming deadlock-free completion even when transfers create multi-parent diamonds or directed cycles.
- `ClientEventuallyResolved`: eventually the client boundary resolves to `COMMIT`, `ABORT`, or conservative `TRANS_UNKNOWN`.

**Liveness assumptions (`LiveSpec` only; `Spec` makes none of them)**:
- Partition transfers are finitely bounded by `MaxTransfers`, and any initiated transfer (`inFlightXfer # None`) eventually completes `CommitTransferLogs` and `FinishTransfer` under weak fairness.
- Weak fairness (`WF_vars`) holds on all protocol message-handling, decision, acknowledgment, reclamation, and retry-resolution steps; spontaneous `InternalAbort`, `DropRunningCtx`, `BeginTransfer`, `LoseClientReply`, and `EvictTDT` have no fairness requirement.

## Relation to Paper Appendix C (`2pc_tla`) and Targeted Ablation Checks

The paper's Appendix C draft specification (`2pc_tla`) provides the uniform-node message skeleton (`PrepareReq`, `PrepareResp`, `Commit`, `Abort`, `Ack`, phase-boundary child merge, and non-blocking duplicate-prepare replies), but cannot be used directly without refinement: it marks initially uninvolved destination streams `RUNNING` at `Init` and omits `MigrateData` state migration in `AddIntermediateParticipant` (violating `Consistency` in 7 states when a fresh destination stream aborts in `RUNNING`), omits the per-transaction `lock_t` / `blocked` concurrency discipline of Algorithms 2–3, omits liveness properties, and replies `"no"` in `TOMBSTONE` (the Section 5.1 lying-participant bug).

Removing each of these core mechanisms from `Tree2PC.tla` produces an immediate TLC counterexample, confirming that the corresponding safety invariants and liveness properties actively exercise them:

| Mutation | Config | Result |
|---|---|---|
| Paper Appendix C `2pc_tla` (`IDLE` omitted; no `MigrateData` on fresh stream) | 3 streams (`r -> {a}`, fresh `b`) | Violates `Consistency` (`Agreement`) in 7 states |
| Remove `~blocked[n]` from 2PC phase-log commits (skip `lock_t` block in Algorithms 2–3) | `Tree2PCTransfer.cfg` | Violates `TransferPrinciple` (and `MinParticipantSet`) in 5 states (prepare/commit races past transfer before `interm` records `dst`) |
| Replace `prep_unknown` with `no` after TCT + TDT eviction ("lying participant", Fig. 6) | `Tree2PCTransfer.cfg` | Violates `ClientReplyConsistent` in 16 states (returns `ABORT` for a committed transaction) |
| Disable `Handle2pcDuplicatePrepareRequest` (wait on downstream children in cycles, §4.6) | `LivenessCircular.cfg` | Violates `EventuallyAllDecide` in 8 states (cyclic `PrepareReq` deadlock between `a` and `b`) |
| Remove `WF_vars(FinishTransfer)` from `Fairness` | `LivenessTransfer.cfg` | Violates `EventuallyAllDecide` in 7 states (`src` stays blocked mid-transfer) |

## Reachability Witnesses

Each witness invariant claims a target protocol scenario is unreachable; TLC must **violate** it (`REACHED`) to confirm the path is exercisable.

| Witness | Scenario Confirmed Reachable | Base Config | Result |
|---|---|---|---:|
| `NoCommitTombstone` | Full commit completes and all active streams reach `TOMBSTONE` | `Coverage.cfg` | REACHED (10) |
| `NoInternalAbortPropagation` | Participant `InternalAbort` propagates upward via `"no"` vote and aborts `Root` through `TOMBSTONE` | `Coverage.cfg` | REACHED (9) |
| `NoTransferInRunning` | Partition transfers to fresh `IDLE` stream during `RUNNING`, merges at `PREPARE`, and commits | `Coverage.cfg` | REACHED (14) |
| `NoTransferInPrepare` | Partition transfers to fresh `IDLE` stream during `PREPARE` and inherits `PREPARE` state | `Coverage.cfg` | REACHED (5) |
| `NoTransferInCommit` | Partition transfers during `COMMIT` (`trans_3` in Algorithm 1) and migrates `COMMIT` directly without `interm` | `Coverage.cfg` | REACHED (9) |
| `NoTDTRetryCommit` | After lost client reply, `ForgetCtx`, and `Root` TDT eviction, recreated `Root` recovers `COMMIT` from participant TDT | `Coverage.cfg` | REACHED (15) |
| `NoTransUnknownOnRecreatedRetry` | After lost client reply, `ForgetCtx`, and TDT eviction, recreated `Root` returns `TRANS_UNKNOWN` (Fig. 7) | `Coverage.cfg` | REACHED (16) |
| `NoAbortOnNewCoordUnknown` | Newly created `Root` encountering `prep_unknown` after volatile `RUNNING` context loss returns `ABORT` (§5.2) | `Coverage.cfg` | REACHED (7) |
| `NoCircularPrepare` | Transfer creates 2-cycle `a <-> b`, both nodes enter `PREPARE` exercising `Handle2pcDuplicatePrepareRequest`, and commit | `CoverageCircular.cfg` | REACHED (17) |
| `NoLiveCircularCommit` | Under `LiveSpec`, cyclic transfer graph `a <-> b` prepares, commits, and reclaims all contexts to `TOMBSTONE` | `LiveCoverage.cfg` | REACHED (23) |

## Model Abstractions and Known Simplifications

- **PALF replication abstracted per log stream**: Each log stream is modeled as a single fault-tolerant state machine whose WAL writes (`PREPARE`, `COMMIT`, `ABORT`, `transfer-out`, `transfer-in`) are durable once committed; intra-stream Paxos/arbitration failover is verified separately in [`protocols/arbitration`](../../arbitration/).
- **Single in-flight transfer serialization (`inFlightXfer`)**: Transfers execute sequentially up to `MaxTransfers` times, one three-step transfer (`BeginTransfer` -> `CommitTransferLogs` -> `FinishTransfer`) in flight at a time, exposing interleavings between transfer completion and phase-log commits on `src` and `dst`.
- **Atomic `CommitTransferLogs` across `src` and `dst`**: Matches Section 4.4's distributed transfer transaction (either both `transfer-out` and `transfer-in` commit or both roll back; aborted transfers leave participant state unchanged and are omitted as stuttering steps).
- **Abstract TDT expiry (`EvictTDT`)**: Rather than modeling wall-clock 30-minute timers, `EvictTDT` nondeterministically evicts any `TOMBSTONE` stream's TDT entry when `AllowTDTEvict = TRUE`, over-approximating all possible timer interleavings for safety.
- **Not modeled**: Section 6.1's `Release` lock-release messages and D2PC tree flattening (discussed analytically in the companion proof; neither alters the root commit point or participant coverage), SQL data-plane row-lock contention, and multi-transaction concurrency.
