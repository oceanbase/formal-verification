# TLC Model-Checking Results

- **Primary verified suite (8 completed finite instances)**: The first seven ran on 2026-11-14 with TLC 2.14 (TLA+ Tools release 1.6.0), OpenJDK 8u502, and 15 workers on a 32-vCPU / 236 GiB host. The [results index](completed-results.csv) records the model bounds, state counts and TLC fingerprint-collision estimates.
- **Specification**: `Arbitration.tla` (918 lines including comments; protocol actions, invariants, and properties are semantically identical to the 2026-11-14 verified snapshot). Terminology mapping: [`README.md`](README.md).

This specification models OceanBase PALF mechanisms (two-tuple log barrier, stale-entry truncation upon configuration installation, `StartWorking`, on-demand `ConfirmConfig`, and arbiter pushes with proposal catch-up) and complements the companion protocol-model proof (*Safety and Liveness of an Arbitration Protocol Model*). Every row in the tables below exhausted its finite state space completely (`exit 0`, TLC completion marker, no errors, empty final queue). Reported depth is the completion depth reported by TLC, not a configured depth cutoff.

## Completed Finite-Instance Checks

### Safety

| Config | Layout | `MaxProposal` | `MaxLogLen` | `MaxConfigSeq` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| `Arbitration.cfg` | 2F1A | 3 | 2 | 4 | 4,359,408 | 18,353,856 | 42 | 02m 22s | Pass (exhausted) |
| `ArbitrationBigPid.cfg` | 2F1A | 4 | 2 | 4 | 18,798,970 | 80,597,583 | 48 | 08m 46s | Pass (exhausted) |
| `ArbitrationBigLog.cfg` | 2F1A | 3 | 3 | 5 | 24,564,480 | 103,719,388 | 48 | 10m 12s | Pass (exhausted) |
| `Arbitration4FP2C2.cfg` | 4F1A | 2 | 1 | 2 | 38,336,462 | 321,215,953 | 37 | 01h 46m | Pass (exhausted) |
| `Arbitration4FP2C3.cfg` | 4F1A | 2 | 1 | 3 | 320,782,868 | —* | 40 | 14h 07m* | Pass (exhausted) |
| `Pruned4FP3L1C3.cfg` | 4F1A | 3 | 1 | 3 | 476,836,999 | 4,376,870,206 | 45 | 8h 45m | Pass (exhausted) |

*\*`Arbitration4FP2C3.cfg` completed across a checkpoint resume (`38,944 s` prior attempt + `11,894 s` continuation = `50,838 s`, i.e., `14h 07m` cumulative attempt wall time; the continuation footer alone reports `03h 18m` and `921,423,476` post-recovery generated states).*

The (3, 1, 3) run used 60 workers and finished at 05:38 Beijing time (UTC+8) on 2026-11-23 with an empty queue and exit code 0. It used [PrunedSpec](Pruned4F.tla) with full-replica symmetry and checked the eight state invariants below.

**Fingerprint collision estimates**: TLC uses 64-bit state fingerprints. For the five `Spec` safety runs, reported tool estimates (retained verbatim in [`completed-results.csv`](completed-results.csv)) range from `3.3E-6` (`Arbitration.cfg`) to `0.010` optimistic / `0.016` actual (`Arbitration4FP2C3.cfg`, continuation log); these are probabilistic tool estimates rather than observed collisions. The (3, 1, 3) run reported an actual-fingerprint estimate of 3.6%.

**Checked safety invariants and properties (8 invariants + 3 monotonicity properties)**:

| Property | Related theorem or lemma | Meaning |
|---|---|---|
| `TypeOK` | — | Type safety of all state variables |
| `LogMatching` | — | Two entries with the same proposal number at the same LSN imply identical prefixes |
| `LeaderCompleteness` | Theorem 4.3(a) | Every `"Leader"` holds all committed entries whose proposal number is at most its own |
| `RecoveryComplete` | Theorem 4.3(a) | In every state, any candidate able to complete Prepare from any valid prepare quorum recovers every committed entry |
| `Agreement` | Theorem 4.3(b) | No LSN commits under two different proposal numbers |
| `ElectableConfigsAdjacent` | Lemma 4.1 (Lemma A.2) | Electable configurations (held by some member of `S`, with a majority of `P` holding no newer version) have commit groups `S` differing by at most one replica |
| `OneLeaderPerProposal` | Lemma 4.1 (Lemma A.3) | At most one replica completes Prepare per proposal number |
| `OneActiveLeader` | Lemma 4.1 consequence | At most one leader can advance its commit point at a time |
| `CommittedMonotonic` | — | The set of committed entries only grows |
| `ProposalMonotonic` | — | Each replica's promised proposal number is nondecreasing |
| `ConfigVersionMonotonic` | — | Each replica's installed configuration version is nondecreasing |

`ElectableConfigsAdjacent` ignores liveness and promised proposal numbers, so it over-approximates actual electability. Pairwise-adjacent groups number at most two—corresponding to Lemma 4.1's invariant of at most one committed configuration plus one pending single-member change.

### Liveness (`LiveSpec`, no symmetry)

| Config | Layout | `MaxProposal` | `MaxLogLen` | `MaxConfigSeq` | Distinct States | Generated States | TLC Depth | Wall Time | Result |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| `Liveness.cfg` | 2F1A | 3 | 1 | 4 | 1,292 | 1,880 | 23 | 05s | Pass (exhausted) |
| `Liveness4F.cfg` | 4F1A | 5 | 1 | 7 | 5,741,034 | 13,877,398 | 49 | 40m 12s | Pass (exhausted) |

Symmetry reduction is disabled because TLC liveness checking is unsound under symmetry.

**Checked liveness properties (Theorem 4.4)**:
- `EventuallyStableLeader == <>[](\E l \in F : StableLeader(l))`: eventually a live full-replica leader with no pending configuration change and a live accept quorum persists forever.
- `WritesCommit`: every log position held by a live leader eventually commits unless that replica crashes or loses leadership (stated per position so it does not rely on writes being bounded).

**Liveness assumptions (`LiveSpec` only; `Spec` makes none of them)**, holding from `Init` onwards (recovery after an arbitrary messy prefix of competing candidates, wrong degradations, or restarts is not covered):
- Failures are permanent and always a minority of `Server` (at most 1 of 3 in 2F1A; at most 2 of 5 in 4F1A).
- Election is stable: no full replica campaigns while another live full replica is past `"Follower"`, `A` pushes as election leader only while every live full replica is a `"Follower"`, and a stuck candidate retries only with a proposal above every live replica's (or steps down via `LoseElection` if it can no longer be elected).
- Failure detection is accurate: only failed full replicas are degraded (`DegradeLive`), and a leader runs `ConfirmConfig` only when it has a failed member to degrade (`ConfirmLive`).
- Weak fairness (`WF_vars`) for all protocol actions except `ClientWrite` and `CrashLive`.

**Parameter justification for liveness bounds**:
- 4F1A (up to 2 permanent failures, up to 3 leaders): `MaxConfigSeq = 7` covers 3 `StartWorking` logs + 2 confirmations + 2 degradations; `MaxProposal = 5` covers 3 elections + 2 retries.
- 2F1A (up to 1 permanent failure, up to 2 leaders): `MaxConfigSeq = 4` covers 2 `StartWorking` logs + 1 confirmation + 1 degradation; `MaxProposal = 3` covers 2 elections + 1 retry.

## Non-Vacuity (Ablation) Checks

Removing key mechanisms produces counterexamples, confirming the properties are not vacuously satisfied:

| Mutation | Layout / Config | Result |
|---|---|---|
| Remove `ConfigConfirmed(l)` from `Degrade` | 4F1A (`Arbitration4FP2C3`) | Violates `ElectableConfigsAdjacent` in 11 states (5 s) |
| Remove `ConfigConfirmed(l)` and `ElectableConfigsAdjacent` | 4F1A (`Arbitration4F`, `C=4`) | Violates leader completeness / loses committed entry in 21 states (Example 1) |
| Remove all fairness (`Spec` without `Fairness`) | 2F1A (`Liveness`) | Violates liveness in 13 states |
| Remove `WF` on `DegradeLive` | 2F1A (`Liveness`) | Violates liveness in 10 states |
| Remove `WF` on `CommitEntries` | 2F1A (`Liveness`) | Violates liveness in 11 states |
| Remove `WF` on `ConfirmLive` | 2F1A (`Liveness`) / 4F1A (`Liveness4F`) | Violates liveness in 16 states (2F1A) / 19 states (4F1A) |
| Remove `ArbiterAdoptProposal` (`ArbiterAdoptLive`) | 4F1A (`Liveness4F`) | Violates liveness: stuck election after two full-replica failures (~310K states, 1m 12s) |

## Reachability Witnesses

Each witness invariant claims an interesting state is unreachable; TLC must **violate** it (`REACHED`) to prove the path is exercisable. (With 8 workers, trace lengths need not be minimal.)

| Witness | Path Confirmed Reachable | 2F1A | 4F1A |
|---|---|---:|---:|
| `NoReconfirming` | Prepare completes and enters log recovery | REACHED (4) | — |
| `NoLeader` | Log reconfirmation completes (`StartWorking` commits) | REACHED (7) | REACHED (9) |
| `NoArbiterPush` | `A` pushes its configuration to a lagging full replica | REACHED (6) | REACHED (7) |
| `NoArbiterPushBesideLeader` | `A` pushes while some full replica holds a leader role (no lease assumed) | REACHED (7) | REACHED (7) |
| `NoArbiterAdopt` | `A` adopts a higher promised proposal number | REACHED (7) | REACHED (8) |
| `NoCommittedEntry` | Log entry commits | REACHED (10) | REACHED (14) |
| `NoDegradeCommitted` | Degradation commits and a subsequent entry commits past its barrier | REACHED (12) | REACHED (16) |
| `NoDegradeAfterConfirm` | New leader confirms inherited config and degrades during reconfirmation | REACHED (8) | REACHED (12) |
| `NoHalfGroupCommit` | `S` shrinks to half of `F` and commits afterwards (two degradations in 4F1A) | — | REACHED (21) |
| `NoCommitWithFAndArbiterDown` | One full replica and `A` are down, yet 4F1A commits without degradation | — | REACHED (17) |
| `NoUpgradeAfterDegrade` | Degraded learner catches up on committed entries and is upgraded | REACHED (16) | REACHED (22) |
| `NoReconfirmAfterDegrade` | After degradation, a new leader reconfirms under higher proposal and recovers committed entries | REACHED (17) | REACHED (22) |
| `NoStaleTruncate` | Receiver discards stale entries on accepting a leader configuration | REACHED (12) | REACHED (16) |
| `NoArbiterStaleTruncate` | Receiver discards stale entries on accepting an arbiter push | REACHED (13) | REACHED (16) |
| `NoLearnerWindow` | Single-copy window: all members of degraded `S` crash while a live learner lacks committed entries | REACHED (13) | REACHED (18) |

Liveness scenario witnesses (`LiveCoverage.cfg`, 2F1A under `LiveSpec`):

| Witness | Scenario Confirmed Reachable | Result |
|---|---|---|
| `NoServingAfterFCrash` | One full replica fails; survivor degrades it and serves | REACHED (11) |
| `NoServingAfterLeaderCrash` | Leader fails; new leader recovers its committed entries, confirms, degrades, and serves | REACHED (22) |
| `NoServingAfterArbiterCrash` | `A` fails and full replicas continue serving | REACHED (8) |

## Model Abstractions and Known Simplifications

- **No election leases**: multiple election leaders may coexist; configuration safety relies solely on proposal numbers and configuration-version filtering in `Promise`.
- **Shared-state communication**: actions read peers' current state directly rather than modeling an explicit message bag with delayed or duplicated messages (handled analytically in the companion protocol-model proof).
- **Post-election Prepare gating**: `Prepare(c, p)` requires `CanBeElected(c)`, abstracting PALF's two-phase `Election` → `LogReconfirm` transition so candidates that cannot win an election do not start Prepare.
- **Recovery reads end-of-Prepare state**: `RecoverLog` selects from voters' current `(acc, LSN)` rather than snapshots captured at `Promise` time (after promising, a voter's log can only be modified by a higher-numbered leader; for safety, allowing reads of higher-numbered logs is a conservative over-approximation).
- **Follower commit point not tracked**: `TruncateStaleEntries` may truncate slightly more broadly than PALF (which only truncates uncommitted entries in the sliding window).
- **ACK-based commits and pre-sync (`matchIndex`)**: matches PALF's `match_lsn_map_`; ACKs persist on the leader even if a follower is later truncated by another leader, and are cleared only on step-down, crash, or new leadership.
- **Arbiter pushes**: `ArbiterPushConfig` may target any full replica (PALF targets `alive_paxos_memberlist_`).
- **Upgrade catch-up**: `Upgrade` requires the learner to match the leader's full log (PALF allows a small gap protected by the barrier check).
- **Not modeled**: permanent disk loss, lease reads, general add/remove/replace beyond degrade/upgrade, flashback (`mode meta`), and odd numbers of full replicas.

## Exploratory Runs (Outside the 8 Completed Instances)

- An additional 4F1A exploration at `(P, L, C) = (3, 1, 2)` was stopped by wall-time budget after exploring `364,224,473` distinct states (progress depth 29, queue `55,978,846`) with no property violation reported. Because it did not exhaust the queue, it is **not** counted among the 8 completed checks and its progress depth is not claimed as a complete coverage bound.
- `Arbitration4F.cfg` (`P=2, L=1, C=4`) and `Pruned4F.tla` / `Pruned4F.cfg` (`P=3, L=1, C=4`) are retained in the repository as exploratory larger-bound configurations (e.g., for reproducing the 21-step `C=4` data-loss ablation when `ConfigConfirmed` is removed).
