# OceanBase arbitration replica

For a single OceanBase log stream, full replicas store redo. The arbitration replica stores only protocol metadata and votes in leader elections and membership changes.

## Protocol model guarantees

- **Safety (Theorem 4.3).** When a full-replica leader completes recovery, it holds every entry committed in a lower-numbered proposal. At most one entry can commit at each log position, even across membership changes.
- **Liveness (Theorem 4.4).** Under the protocol model's progress assumptions, a full replica eventually becomes and remains leader, and every write it subsequently accepts eventually commits.

[Proof (PDF)](proof/arbitration-proof.pdf) · [LaTeX source](proof/arbitration-proof.tex)

## TLA+ results

A separate TLA+ model captures PALF's arbitration mechanisms. TLC completed six safety checks and two liveness checks on bounded configurations with two or four full replicas and one arbiter. All eight runs finished without a property violation. The largest safety run explored 476,836,999 distinct states.

[Specification](tla/Arbitration.tla) · [Results by configuration](tla/results.md) · [Run the checks](tla/README.md) · [BibTeX](artifact.bib)
