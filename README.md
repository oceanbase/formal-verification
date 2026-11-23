# OceanBase Formal Verification

This repository collects correctness proofs and executable specifications for OceanBase protocols.

| Protocol | Correctness question | Materials |
| --- | --- | --- |
| [Arbitration](protocols/arbitration/) | Can a replica that stores no redo help elect a leader while preserving committed entries across membership changes? When can writes resume after failures? | [Proof (PDF)](protocols/arbitration/proof/arbitration-proof.pdf) · [TLA+ specification](protocols/arbitration/tla/Arbitration.tla) · [TLC results](protocols/arbitration/tla/results.md) |
| [LCL+](protocols/lcl/) | Can distributed transactions detect and resolve multi-outdegree and hybrid deadlocks using local neighbor messages without false rollbacks or multi-victim kills? | [Proof (PDF)](protocols/lcl/proof/lcl-proof.pdf) · [TLA+ specification](protocols/lcl/tla/LCL.tla) · [TLC results](protocols/lcl/tla/results.md) |
