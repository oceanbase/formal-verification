# OceanBase Arbitration

An arbitration replica votes in elections and on membership changes. Full replicas store the redo log.

This directory is reserved for the arbitration proof and its companion model. The initial contribution establishes the following layout.

| Directory | Planned contents |
| --- | --- |
| [proof/](proof/) | A standalone proof of safety and conditional liveness, with the PDF and its LaTeX source side by side. |
| [proof/figures/](proof/figures/) | Figures referenced by the LaTeX source. |
| [tla/](tla/) | TLA+ modules and a TLC model-checking configuration. |
