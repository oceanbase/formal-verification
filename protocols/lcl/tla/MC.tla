-------------------------------- MODULE MC ---------------------------------
EXTENDS LCL, TLC

(***************************************************************************)
(* Concrete WFG topologies for finite-instance model checking of LCL/LCL+. *)
(***************************************************************************)

\* 1. Acyclic multi-outdegree diamond DAG: 10 -> {20, 30} -> 40
V_Diamond == {10, 20, 30, 40}
E_Diamond == {<<10, 20>>, <<10, 30>>, <<20, 40>>, <<30, 40>>}
S_Diamond == (10 :> 1 @@ 20 :> 1 @@ 30 :> 2 @@ 40 :> 2)

\* 2. High-AP annulus chain (99 -> 80 -> 10) + distributed cycle (10 <-> 20)
\*    + multi-outdegree downstream non-cycle tail (10 -> 90).
\*    Here scc = {10, 20}, w = AsgWidth(scc) = 2, d = SccDiam(scc) = 1.
V_AnnulusTail == {10, 20, 80, 90, 99}
E_AnnulusTail == {<<99, 80>>, <<80, 10>>, <<10, 20>>, <<20, 10>>, <<10, 90>>}
S_AnnulusTail == (99 :> 1 @@ 80 :> 1 @@ 10 :> 2 @@ 20 :> 3 @@ 90 :> 3)

\* 3. Multi-cycle SCC (Figure 17(a)): 5 <-> 15 and 20 -> 15 -> 10 -> 20,
\*    plus high-AP upstream annulus vertex 50 -> 5 (w = 1, d = 3, N = 2 cycles).
V_MultiCycle == {5, 10, 15, 20, 50}
E_MultiCycle == {<<50, 5>>, <<5, 15>>, <<15, 5>>, <<20, 15>>, <<15, 10>>, <<10, 20>>}
S_MultiCycle == (50 :> 1 @@ 5 :> 1 @@ 15 :> 2 @@ 10 :> 1 @@ 20 :> 2)

\* 4. Hybrid local + distributed WFG (Figure 6, LCL+ Stage 0 + Stage 1-3):
\*    Server 1 local lasso: 60 -> 10 <-> 25 (victim 25, sparing stem 60);
\*    Hybrid distributed cycle: 12 -> 30 (Server 1) -> 40 (Server 2) -> 12.
V_Hybrid == {10, 12, 25, 30, 40, 60}
E_Hybrid == {<<60, 10>>, <<10, 25>>, <<25, 10>>, <<12, 30>>, <<30, 40>>, <<40, 12>>}
S_Hybrid == (60 :> 1 @@ 10 :> 1 @@ 25 :> 1 @@ 12 :> 1 @@ 30 :> 1 @@ 40 :> 2)

\* 5. Chained SCCs (Figure 17(b)): high-AP annulus 95 -> topmost SCC {30 <-> 40}
\*    -> downstream SCC {10 <-> 20} via surviving bridge 30 -> 10.
\*    Killing 40 in Period 1 leaves 95 -> 30 -> 10 (w = 2) with pumped LCLV at 30.
V_Chained == {10, 20, 30, 40, 95}
E_Chained == {<<95, 30>>, <<30, 40>>, <<40, 30>>, <<30, 10>>, <<10, 20>>, <<20, 10>>}
S_Chained == (95 :> 1 @@ 30 :> 1 @@ 40 :> 2 @@ 10 :> 2 @@ 20 :> 3)

=============================================================================
