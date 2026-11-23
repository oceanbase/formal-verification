# OceanBase arbitration replica

For a single OceanBase log stream, full replicas store redo. The arbitration replica stores only protocol metadata and votes in leader elections and membership changes.

## Protocol model guarantees

- **Safety (Theorem 4.3).** When a full-replica leader completes recovery, it holds every entry committed in a lower-numbered proposal. At most one entry can commit at each log position, even across membership changes.
- **Liveness (Theorem 4.4).** Under the protocol model's progress assumptions, a full replica eventually becomes and remains leader, and every write it subsequently accepts eventually commits.

[Proof (PDF)](proof/arbitration-proof.pdf) · [LaTeX source](proof/arbitration-proof.tex)

## TLA+ results

TLC completed six bounded safety checks and two bounded liveness checks across 2F1A and 4F1A configurations without finding a counterexample. The 4F1A safety check with three proposal numbers, one log position and a maximum configuration sequence number of three explored 476,836,999 distinct states.

[Specification](tla/Arbitration.tla) · [Results by configuration](tla/results.md) · [Run the checks](tla/README.md) · [BibTeX](artifact.bib)
