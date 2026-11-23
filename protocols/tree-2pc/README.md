# OceanBase tree-structured two-phase commit

Coalesced single-machine log streams serve as two-phase commit (2PC) participants across co-located partitions. As partitions migrate during active transactions, each log stream acts as coordinator to its downstream transfer and SQL children and as participant to its parent, while a bounded-retention Transaction Data Table (TDT) alongside `prepare_unknown` and `trans_unknown` states prevents fabricated outcomes after context reclamation.

## Protocol model guarantees

- **Participant-set and transfer coverage (Theorems 2.2, 4.1, and 4.3).** Per-transaction lock synchronization serializes phase-log commits with `transfer-out`/`transfer-in` migration so every partition's hosting log stream either lies in the coordinator-rooted commit graph or has already migrated a terminal outcome.
- **Safety (Theorem 6.1).** No two log streams reach conflicting terminal outcomes (`COMMIT` vs. `ABORT`), even across multi-hop and circular transfers; once all active streams reclaim context (`TOMBSTONE`), every final partition host holds the root's decision; client retries never fabricate `ABORT` for a committed transaction or `COMMIT` for an aborted one.
- **Liveness (Theorem 6.2).** Under bounded transfers and weak fairness, every active log stream—including across directed transfer cycles—eventually records a common terminal outcome and reclaims its transaction context.

[Proof (PDF)](proof/tree-2pc-proof.pdf) · [LaTeX source](proof/tree-2pc-proof.tex)

## TLA+ results

A companion TLA+ model captures OceanBase's dynamic log-stream commit graph, three-step lock-synchronized partition transfers, circular duplicate-prepare handling, TCT reclamation, TDT expiry, and coordinator retries. TLC completed six safety checks and three liveness checks across bounded configurations with three to five log streams and up to two concurrent partition transfers. All nine runs finished without a property violation. The largest safety run explored 42,710,637 distinct states.

[Specification](tla/Tree2PC.tla) · [Results by configuration](tla/results.md) · [Run the checks](tla/README.md) · [BibTeX](artifact.bib)
