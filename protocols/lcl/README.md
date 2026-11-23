# OceanBase lock chain length deadlock detection

Transactions waiting on row locks in OceanBase form a distributed wait-for graph in which a vertex may wait on multiple resources concurrently. Each vertex exchanges fixed-size lock chain length (`LCLV`) and candidate victim (`PuID`) metadata with its immediate downstream holders, while `LCL+` adds local depth-first pre-proliferation (`Stage 0`) to accelerate hybrid local-and-distributed deadlock resolution. [TOCS paper](https://doi.org/10.1145/3768621)

## Protocol model guarantees

- **Safety (Theorems 5.1 and 5.11).** Under arbitrary message loss, reordering, and phase-timer switches, every vertex terminated by `Stage 0` or `Stage 3` is the unique maximum-priority vertex of a genuine simple deadlock cycle, and at most $N$ vertices are terminated in a graph with $N$ simple cycles (no manslaughter and no multi-kill). When a period supplies $\max(w, 1)$ proliferation rounds and $2d$ spread rounds for a topmost strongly connected component, `Stage 3` selects its unique highest-priority vertex.
- **Liveness (Theorem 5.12).** Under periodic execution delivering the proliferation and spread round bounds for each current topmost strongly connected component, every local, distributed, or chained deadlock cycle is resolved within at most $N$ periods.

[Proof (PDF)](proof/lcl-proof.pdf) · [LaTeX source](proof/lcl-proof.tex)

## TLA+ results

A companion TLA+ specification models both OceanBase's asynchronous timer-sliced `LCL+` service (`Spec`, allowing message loss, early phase transitions, `Stage 0` local pre-proliferation, and concurrent mid-spread aborts) and the paper's round-complete deduction model (`RoundSpec` and `LiveSpec`). TLC completed six safety checks and two multi-period liveness checks across acyclic multi-outdegree, high-priority annulus, multi-cycle SCC, hybrid local-distributed, and chained-SCC topologies without a property violation. The largest asynchronous safety check explored 108,887 distinct states (304,650 generated states).

[Specification](tla/LCL.tla) · [Results by configuration](tla/results.md) · [Run the checks](tla/README.md) · [BibTeX](artifact.bib)
