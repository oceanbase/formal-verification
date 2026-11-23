# Arbitration Replica TLA+ Specification

Single-log-stream TLA+ model of OceanBase PALF's dual-quorum Paxos with a data-less arbitration replica `A`. The number of full replicas `F` is configurable (checked for 2F1A and 4F1A). The model covers election, log reconfirmation (Prepare phase, log recovery, `StartWorking` log), configuration confirmation, log replication and commitment, degradation and upgrade, arbiter configuration pushes and proposal catch-up, and crashes/restarts.

The model exercises PALF mechanisms (two-tuple log barrier, stale-entry truncation upon configuration installation, `StartWorking`, on-demand `ConfirmConfig`, and arbiter pushes with proposal catch-up). It complements the companion protocol-model proof ([*Safety and Liveness of an Arbitration Protocol Model*](../proof/arbitration-proof.pdf), which uses an explicit durable `acc` and metadata-only configuration propagation for the safety argument and additional progress assumptions for liveness). The checked properties describe the TLA+ model. The published checks use the finite bounds listed below.

- Detailed results and model abstractions: [`results.md`](results.md)
- Machine-readable eight-case summary: [`completed-results.csv`](completed-results.csv)

## Reproduce a check

From this directory, download the same TLC executable used for the recorded results and run the smallest liveness check. The file is from the [TLA+ Tools 1.6.0 release](https://github.com/tlaplus/tlaplus/releases/tag/v1.6.0), which contains TLC 2.14. Its SHA-256 digest is `71ce43150b6ee0a76cc33849ec45b2c6ae4323dc933b0acaef0928668ed0de72`.

```sh
curl -fL https://github.com/tlaplus/tlaplus/releases/download/v1.6.0/tla2tools.jar -o tla2tools.jar
TLC_WORKERS=2 TLC_HEAP=1g ./run.sh Liveness
```

TLC should finish with “Model checking completed. No error has been found.” The recorded run visited 1,292 distinct states at depth 23. The base safety instance and a reachability witness can be run independently.

```sh
TLC_WORKERS=4 TLC_HEAP=2g ./run.sh Arbitration
TLC_WORKERS=2 TLC_HEAP=1g ./check-witnesses.sh NoLeader
```

The witness succeeds when its output says `REACHED`. Its invariant asserts that the target state is unreachable, so a counterexample gives the desired path. The runner disables deadlock checking because the finite bounds allow terminal states.

To run the 4F1A safety check at (3, 1, 3), use the following command. Set `TLC_HEAP` and `TLC_DIRECT` for the available memory.

```sh
MODULE=Pruned4F TLC_WORKERS=60 ./run.sh Pruned4FP3L1C3
```

## Files

| File | Purpose |
|---|---|
| `Arbitration.tla` | Complete specification (`Spec`, `LiveSpec`), all safety/liveness properties, and coverage witnesses |
| `Arbitration.cfg` | 2F1A safety check, `(P, L, C) = (3, 2, 4)` |
| `ArbitrationBigPid.cfg` | 2F1A safety check, `(P, L, C) = (4, 2, 4)` |
| `ArbitrationBigLog.cfg` | 2F1A safety check, `(P, L, C) = (3, 3, 5)` |
| `Arbitration4FP2C2.cfg` | 4F1A safety check, `(P, L, C) = (2, 1, 2)` (exhaustive) |
| `Arbitration4FP2C3.cfg` | 4F1A safety check, `(P, L, C) = (2, 1, 3)` (exhaustive) |
| `Liveness.cfg` | 2F1A liveness check, `(P, L, C) = (3, 1, 4)` (no symmetry) |
| `Liveness4F.cfg` | 4F1A liveness check, `(P, L, C) = (5, 1, 7)` (no symmetry) |
| `Arbitration4F.cfg` | Exploratory larger-bound 4F1A config, `(P, L, C) = (2, 1, 4)` (outside the eight completed runs) |
| [Pruned4FP3L1C3.cfg](Pruned4FP3L1C3.cfg) | 4F1A safety check, `(P, L, C) = (3, 1, 3)`. [Results](results.md#safety) |
| `Pruned4F.cfg` | Exploratory 4F1A configuration, `(P, L, C) = (3, 1, 4)` |
| `Coverage.cfg`, `Coverage4F.cfg`, `LiveCoverage.cfg` | Shared base configs for reachability witnesses |
| `completed-results.csv` | Machine-readable table of the eight completed runs (including TLC fingerprint-collision estimates) |
| `run.sh` | Run a config: `[TLC_WORKERS=N] [TLC_HEAP=12g] [TLC_DIRECT=32g] ./run.sh <Config>` |
| `check-witnesses.sh` | Run reachability witnesses (each should output `REACHED`); override base via `BASE=LiveCoverage` or `BASE=Coverage4F` |

### Requirements

- Java 8 or newer on `PATH`, or set `JAVA` to the desired Java executable.
- Place TLC 2.14 at `tla2tools.jar` in this directory or set `TLA2TOOLS` to an absolute path to the jar.
- For large 4F1A checks (`Arbitration4FP2C2`, `Arbitration4FP2C3`), set `TLC_DIRECT` (e.g., `TLC_WORKERS=15 TLC_HEAP=16g TLC_DIRECT=32g`) to enable TLC's `OffHeapDiskFPSet` and periodic checkpointing.

## Paper-to-Model Mapping

Names follow Sections 3–4 of the paper:

| Paper (Sections 3–4) | TLA+ Model |
|---|---|
| Proposal number (`proposal_id`) | `proposal[s]`: highest promised proposal; a leader's own proposal number |
| Log commit membership `S` | `config[s].curr.commitGroup` |
| Election membership `P = S ∪ {A}` | `ElectionGroup(s)` |
| Prepare quorum (majority of `P`) | `IsPrepareQuorum(Q, c)` |
| Accept quorum (majority of `S`) | `AcceptedBy(l, i, S)`, `CanCommitUpTo` |
| Follower log ACKs (`match_lsn_map_`) | `matchIndex[l][f]`, `Acked(l, f, i)`: leader decides commits and pre-change sync solely from ACKs |
| Prepare phase | `Prepare(c, p)`, `Promise(v, c)` (`role = "Candidate"`) |
| Log recovery from largest `(acc, LSN)` | `RecoverLog(c)`, `RecoverySources(Q)`, `Acc(f)` (transitions to `"Reconfirming"`) |
| `StartWorking` log | `StartWorking(l)` (configuration proposal; commit transitions to `"Leader"` and commits through barrier) |
| Configuration confirmation | `ConfirmConfig(l)`, `ConfigConfirmed(l)` |
| Degradation / Upgrade | `Degrade(l, s)`, `Upgrade(l, m)` |
| Accepting configuration / redo | `AcceptConfig(v, l)` / `AcceptEntry(f, l)` |
| Two-tuple barrier & stale truncation | `config[s].barrier`, `MatchesBarrier`, `TruncateStaleEntries` |
| Pre-change log synchronization | `MajorityHoldsLeaderLog(l, S)` (required by `CanDegrade`, `Upgrade`, `StartWorking`) |
| Commit freeze | `CommitEntries` requires `pendingChange[l] = None` |
| Arbiter config push & catch-up | `ArbiterPushConfig(f)`, `ArbiterAdoptProposal(f)` |

### Parameter Semantics

- **`MaxLogLen`**: bounds data-log positions (`Len(log[f]) <= MaxLogLen`). `StartWorking` is modeled as a configuration proposal and quorum commit (matching PALF's `LogConfigMeta`); `CommitConfig` commits the recovered data prefix through its barrier without consuming a data-log slot. Thus `MaxLogLen = 1` in 4F1A still exercises single-position recovery and commitment, while 2F1A also checks multi-entry logs (`MaxLogLen = 2, 3`).
- **`MaxConfigSeq`**: bounds configuration sequence numbers, counting `StartWorking`, `ConfirmConfig`, `Degrade`, and `Upgrade` proposals.

### Theorem-to-Property Mapping

| Paper / Companion Proof | Checked TLA+ Properties |
|---|---|
| Theorem 4.3(a) Leader completeness | `LeaderCompleteness` (every `"Leader"` holds all committed entries with `e.proposal <= proposal[l]`) and `RecoveryComplete` (checked in every state: any candidate able to complete Prepare from any valid prepare quorum recovers every committed entry) |
| Theorem 4.3(b) Agreement | `Agreement` (no LSN commits under two distinct proposal numbers) |
| Lemma 4.1 (companion Lemma A.2) | `ElectableConfigsAdjacent` (electable configurations have log commit memberships differing by at most one replica) |
| Lemma 4.1 consequences (companion Lemma A.3) | `OneLeaderPerProposal` (at most one replica completes Prepare per proposal) and `OneActiveLeader` (at most one leader can advance its commit point at a time) |
| Theorem 4.4 Liveness | `EventuallyStableLeader` and `WritesCommit` under `LiveSpec` |
