# OceanBase Formal Verification

This repository collects correctness proofs and executable specifications for OceanBase protocols.

| Protocol | Correctness question | Materials |
| --- | --- | --- |
| [Arbitration](protocols/arbitration/) | Can a replica that stores no redo help elect a leader while preserving committed entries across membership changes? When can writes resume after failures? | [Proof (PDF)](protocols/arbitration/proof/arbitration-proof.pdf) · [TLA+ specification](protocols/arbitration/tla/Arbitration.tla) · [TLC results](protocols/arbitration/tla/results.md) |
