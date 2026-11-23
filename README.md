# OceanBase Formal Verification

This repository collects correctness proofs and executable specifications for OceanBase protocols.

| Protocol | Correctness question | Materials |
| --- | --- | --- |
| [Arbitration](protocols/arbitration/) | Can a replica that stores no redo help elect a leader while preserving committed entries across membership changes? When can writes resume after failures? | [Proof (PDF)](protocols/arbitration/proof/arbitration-proof.pdf) · [TLA+ specification](protocols/arbitration/tla/Arbitration.tla) · [TLC results](protocols/arbitration/tla/results.md) |
| [Tree-Structured 2PC](protocols/tree-2pc/) | Can coalesced log-stream participants preserve atomic agreement and progress across live partition transfers, circular topologies, and post-reclamation retries? | [Proof (PDF)](protocols/tree-2pc/proof/tree-2pc-proof.pdf) · [TLA+ specification](protocols/tree-2pc/tla/Tree2PC.tla) · [TLC results](protocols/tree-2pc/tla/results.md) |
