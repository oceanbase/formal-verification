-------------------------------- MODULE LCL --------------------------------
(***************************************************************************)
(* Lock Chain Length (LCL and LCL+) distributed deadlock detection and     *)
(* resolution protocol for OceanBase wait-for graphs (WFGs).               *)
(*                                                                         *)
(* Grounded in "LCL+: a Lock Chain Length-based Distributed Deadlock       *)
(* Detection and Resolution Service Built for OceanBase" (ACM TOCS,        *)
(* DOI: 10.1145/3768621, Sections 3-5 and 7, Algorithms 1-2).              *)
(*                                                                         *)
(* The module provides two complementary execution models over the same    *)
(* state variables:                                                        *)
(*                                                                         *)
(*  - Spec (Asynchronous Periodic LCL+ Safety Model, Sections 4.6-4.7,     *)
(*    5.1.1, and 7.1): models OceanBase's periodic timer-driven phases     *)
(*    without oracle knowledge of AsgWidth(scc) or SccDiam(scc).  Messages *)
(*    along edges may fire in any order, duplicate, or be lost; Stage 0    *)
(*    runs local DFS pre-proliferation (Algorithm 2); detection is         *)
(*    integrated into Spread (Section 4.6); and detected victims may abort *)
(*    concurrently while other vertices continue Spread.                   *)
(*                                                                         *)
(*  - RoundSpec / LiveSpec (Round-Complete Deduction Model, Algorithm 1    *)
(*    and Section 5): each Proliferation and Spread round applies every    *)
(*    active edge in arbitrary asynchronous order (Definition 4.10) for    *)
(*    ProlifRounds and SpreadRounds rounds before Stage 3 Detection and    *)
(*    period resolution, checking Lemma 5.10, Theorem 5.11, and            *)
(*    multi-period liveness (Section 5.1.2).                               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Vertex,        \* finite subset of Nat \ {0}; integer value represents PrID = AP
  Edges,         \* SUBSET (Vertex \X Vertex): initial irreflexive wait-for edges
  ServerOf,      \* [Vertex -> Nat]: server hosting each transaction vertex
  EnableStage0,  \* BOOLEAN: TRUE for LCL+ (with Stage 0), FALSE for baseline LCL
  MaxLCLV,       \* Nat: bound on LCLV in asynchronous Spec
  MaxPeriods,    \* Nat: bound on periodic resets in asynchronous Spec
  ProlifRounds,  \* Nat: Stage 1 rounds per period in RoundSpec / LiveSpec
  SpreadRounds   \* Nat: Stage 2 rounds per period in RoundSpec / LiveSpec

ASSUME /\ Vertex \subseteq (Nat \ {0})
       /\ Vertex # {}
       /\ \A e \in Edges : e[1] \in Vertex /\ e[2] \in Vertex /\ e[1] # e[2]
       /\ MaxLCLV \in Nat
       /\ MaxPeriods \in Nat \ {0}
       /\ ProlifRounds \in Nat \ {0}
       /\ SpreadRounds \in Nat

VARIABLES
  activeEdges,   \* SUBSET Edges: remaining wait-for edges among unkilled vertices
  phase,         \* {"Stage0", "Prolif", "Spread", "Detect", "Done"}
  period,        \* 1..MaxPeriods: current detection period number
  round,         \* Nat: current round index within Prolif or Spread (RoundSpec)
  pendingEdges,  \* SUBSET activeEdges: edges not yet applied in current round
  dfsStack,      \* Seq(Vertex): active local DFS path during Stage 0 (Algorithm 2)
  stage0Visited, \* SUBSET Vertex: vertices that already started Stage 0 in period
  lclv,          \* [Vertex -> Nat]: dynamic Lock Chain Length Value (Definition 4.4)
  puid,          \* [Vertex -> Vertex]: dynamic PublicID of candidate victim (Def 4.2)
  detected,      \* SUBSET Vertex: victims detected in the current period
  killed         \* SUBSET Vertex: cumulative aborted victims across periods

vars == <<activeEdges, phase, period, round, pendingEdges, dfsStack,
          stage0Visited, lclv, puid, detected, killed>>

-----------------------------------------------------------------------------
(* Graph-Theoretic Definitions (Sections 3 and 5.2-5.3) *)

Max(a, b) == IF a >= b THEN a ELSE b

SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x

SeqElems(s) == {s[i] : i \in 1..Len(s)}

IndexInSeq(s, x) == CHOOSE i \in 1..Len(s) : s[i] = x

\* Walk reachability u => v (Definition 3.2), computed in <= |Vertex| steps.
RECURSIVE ReachSteps(_, _, _)
ReachSteps(E, S, k) ==
  IF k = 0
  THEN S
  ELSE LET next == S \cup {v \in Vertex : \E u \in S : <<u, v>> \in E}
       IN IF next = S THEN S ELSE ReachSteps(E, next, k - 1)

Reachable(E, u) == ReachSteps(E, {u}, Cardinality(Vertex))

\* Proper (non-empty) walk reachability: u can reach v in >= 1 edges.
ProperReachable(E, u) ==
  ReachSteps(E, {v \in Vertex : <<u, v>> \in E}, Cardinality(Vertex))

InCycle(E, u) == u \in ProperReachable(E, u)

\* Two-way connectivity u <=> v (Definition 3.3) and nontrivial SCCs (Section 3.2).
TwoWay(E, u, v) == v \in Reachable(E, u) /\ u \in Reachable(E, v)

SCCOf(E, u) == {v \in Vertex : TwoWay(E, u, v)}

AllNontrivialSCCs(E) ==
  {SCCOf(E, u) : u \in {v \in Vertex : InCycle(E, v)}}

\* Upstream subgraph USG(scc) and annulus subgraph ASG(scc) (Definitions 3.6-3.7).
USG(E, scc) == {u \in Vertex : \E v \in scc : v \in Reachable(E, u)}

ASG(E, scc) == USG(E, scc) \ scc

\* Topmost SCC (Definitions 5.2-5.3): nontrivial SCC with no cycle in ASG(scc).
IsTopmostSCC(E, scc) ==
  /\ scc \in AllNontrivialSCCs(E)
  /\ \A u \in ASG(E, scc) : ~InCycle(E, u)

TopmostSCCs(E) == {scc \in AllNontrivialSCCs(E) : IsTopmostSCC(E, scc)}

\* Local edges on the same server (Section 4.7) and zero-indegree sources.
IsLocalEdge(e) == ServerOf[e[1]] = ServerOf[e[2]]

LocalEdges(E) == {e \in E : IsLocalEdge(e)}

ZeroIndegree(E) ==
  {u \in Vertex :
     /\ (\E v \in Vertex : <<u, v>> \in E)
     /\ ~(\E w \in Vertex : <<w, u>> \in E)}

\* Canonical enumeration of all simple directed cycles in E (anchored at minimum vertex).
RECURSIVE SimpleCyclesFrom(_, _, _, _)
SimpleCyclesFrom(E, start, curr, path) ==
  LET closed == IF <<curr, start>> \in E /\ Len(path) >= 2 THEN {path} ELSE {}
      nextVs == {w \in Vertex :
                   /\ <<curr, w>> \in E
                   /\ w > start
                   /\ w \notin SeqElems(path)}
  IN closed \cup UNION {SimpleCyclesFrom(E, start, w, Append(path, w)) : w \in nextVs}

AllSimpleCycles(E) ==
  UNION {SimpleCyclesFrom(E, s, s, <<s >>) : s \in Vertex}

InitialSimpleCycleCount == Cardinality(AllSimpleCycles(Edges))

RemoveVertices(E, V) == {e \in E : e[1] \notin V /\ e[2] \notin V}

\* Formula (1) of Stage 2 LCL Spread (Definition 4.9):
\* First newL = Max(B.LCLV, A.LCLV); if newL = A.LCLV, B.PuID = Max(A.PuID, B.PuID).
SpreadLCLV(u, v) == Max(lclv[v], lclv[u])

SpreadPuID(u, v) ==
  IF SpreadLCLV(u, v) = lclv[u]
  THEN Max(puid[v], puid[u])
  ELSE puid[v]

\* Stage 3 LCL Detection predicate on edge u -> v (Section 4.5, Algorithm 1 lines 10-13).
DetectsOnEdge(u, v, lMap, pMap) ==
  /\ lMap[v] = lMap[u]
  /\ pMap[v] = pMap[u]
  /\ pMap[v] = v

-----------------------------------------------------------------------------
(* Initial State *)

Init ==
  /\ activeEdges   = Edges
  /\ phase         = IF EnableStage0 THEN "Stage0" ELSE "Prolif"
  /\ period        = 1
  /\ round         = 1
  /\ pendingEdges  = IF EnableStage0 THEN {} ELSE Edges
  /\ dfsStack      = << >>
  /\ stage0Visited = {}
  /\ lclv          = [v \in Vertex |-> 0]
  /\ puid          = [v \in Vertex |-> v]
  /\ detected      = {}
  /\ killed        = {}

-----------------------------------------------------------------------------
(* Stage 0: LCL+ Local Pre-Proliferation (Section 4.7, Algorithm 2)        *)

\* Start a local DFS pre-proliferation walk at vertex u.
\* In Spec, any unkilled vertex with outgoing edges may initiate (covering dynamic
\* lock-wait initiation as well as zero-indegree roots); RoundSpec restricts
\* roots to ZeroIndegree(activeEdges) as written in Algorithm 2 line 1.
Stage0Start(u, onlySources) ==
  /\ phase = "Stage0"
  /\ dfsStack = << >>
  /\ u \notin killed
  /\ u \notin stage0Visited
  /\ IF onlySources THEN u \in ZeroIndegree(activeEdges)
                    ELSE \E v \in Vertex : <<u, v>> \in activeEdges
  /\ dfsStack'      = <<u >>
  /\ stage0Visited' = stage0Visited \cup {u}
  /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                 lclv, puid, detected, killed>>

\* Algorithm 2 lines 4-6: local edge curr -> b revisits b already in dfsStack.
\* The cycle is the suffix of dfsStack starting at b; its max-AP vertex is victim.
Stage0DetectLocalCycle(b) ==
  /\ phase = "Stage0"
  /\ dfsStack # << >>
  /\ LET curr   == dfsStack[Len(dfsStack)]
         idx    == IndexInSeq(dfsStack, b)
         cycSet == {dfsStack[i] : i \in idx..Len(dfsStack)}
         victim == SetMax(cycSet)
     IN /\ <<curr, b>> \in activeEdges
        /\ ServerOf[b] = ServerOf[curr]
        /\ b \in SeqElems(dfsStack)
        /\ detected' = detected \cup {victim}
        /\ dfsStack' = << >>
        /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                       stage0Visited, lclv, puid, killed>>

\* Algorithm 2 lines 7-10: local edge curr -> b to unvisited local vertex b.
Stage0AdvanceLocal(b, bounded) ==
  /\ phase = "Stage0"
  /\ dfsStack # << >>
  /\ LET curr == dfsStack[Len(dfsStack)]
     IN /\ <<curr, b>> \in activeEdges
        /\ ServerOf[b] = ServerOf[curr]
        /\ b \notin SeqElems(dfsStack)
        /\ (~bounded \/ lclv[curr] < MaxLCLV)
        /\ lclv'     = [lclv EXCEPT ![b] = Max(@, lclv[curr] + 1)]
        /\ dfsStack' = Append(dfsStack, b)
        /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                       stage0Visited, puid, detected, killed>>

\* Algorithm 2 lines 11-13: remote edge curr -> b pushes b.LCLV to remote LCL
\* buffer without forwarding the local visited stack.
Stage0PushRemote(b, bounded) ==
  /\ phase = "Stage0"
  /\ dfsStack # << >>
  /\ LET curr == dfsStack[Len(dfsStack)]
     IN /\ <<curr, b>> \in activeEdges
        /\ ServerOf[b] # ServerOf[curr]
        /\ (~bounded \/ lclv[curr] < MaxLCLV)
        /\ lclv'     = [lclv EXCEPT ![b] = Max(@, lclv[curr] + 1)]
        /\ dfsStack' = << >>
        /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                       stage0Visited, puid, detected, killed>>

\* End current DFS walk when no further local branch is taken.
Stage0StopWalk ==
  /\ phase = "Stage0"
  /\ dfsStack # << >>
  /\ dfsStack' = << >>
  /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                 stage0Visited, lclv, puid, detected, killed>>

\* Resolve any local victims detected during Stage 0 and enter Stage 1 Proliferation.
FinishStage0(requireAllSources) ==
  /\ phase = "Stage0"
  /\ dfsStack = << >>
  /\ (requireAllSources => ZeroIndegree(activeEdges) \subseteq stage0Visited)
  /\ LET newKilled == killed \cup detected
         remEdges  == RemoveVertices(activeEdges, detected)
     IN /\ killed'       = newKilled
        /\ activeEdges'  = remEdges
        /\ detected'     = {}
        /\ puid'         = [v \in Vertex |-> v]
        /\ IF requireAllSources /\ AllNontrivialSCCs(remEdges) = {}
           THEN /\ phase'        = "Done"
                /\ round'        = 0
                /\ pendingEdges' = {}
           ELSE /\ phase'        = "Prolif"
                /\ round'        = 1
                /\ pendingEdges' = remEdges
        /\ UNCHANGED <<period, dfsStack, stage0Visited, lclv>>

-----------------------------------------------------------------------------
(* Asynchronous Periodic Model Actions (Spec: Sections 4.6, 5.1.1, 7.1)    *)

\* During Proliferation, any edge may fire (or never fire if lost), bounded by MaxLCLV.
AsyncProlifEdge(e) ==
  /\ phase = "Prolif"
  /\ e \in activeEdges
  /\ lclv[e[1]] < MaxLCLV
  /\ lclv' = [lclv EXCEPT ![e[2]] = Max(@, lclv[e[1]] + 1)]
  /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges, dfsStack,
                 stage0Visited, puid, detected, killed>>

\* Periodic timer switches from Proliferation to Spread at any point.
AsyncProlifToSpread ==
  /\ phase = "Prolif"
  /\ phase' = "Spread"
  /\ UNCHANGED <<activeEdges, period, round, pendingEdges, dfsStack,
                 stage0Visited, lclv, puid, detected, killed>>

\* Integrated Spread + Detection (Section 4.6): receiving a Spread message updates
\* LCLV and PuID via Formula (1) and immediately checks the Stage 3 condition.
AsyncSpreadEdge(e) ==
  /\ phase = "Spread"
  /\ e \in activeEdges
  /\ LET u     == e[1]
         v     == e[2]
         newL  == SpreadLCLV(u, v)
         newP  == SpreadPuID(u, v)
         lMap1 == [lclv EXCEPT ![v] = newL]
         pMap1 == [puid EXCEPT ![v] = newP]
         hit   == DetectsOnEdge(u, v, lMap1, pMap1)
     IN /\ (lMap1 # lclv \/ pMap1 # puid \/ (hit /\ v \notin detected))
        /\ lclv'     = lMap1
        /\ puid'     = pMap1
        /\ detected' = IF hit THEN detected \cup {v} ELSE detected
        /\ UNCHANGED <<activeEdges, phase, period, round, pendingEdges,
                       dfsStack, stage0Visited, killed>>

\* Detected victim aborts asynchronously without a global cluster barrier.
AsyncAbortVictim(v) ==
  /\ phase \in {"Stage0", "Spread"}
  /\ dfsStack = << >>
  /\ v \in detected
  /\ killed'       = killed \cup {v}
  /\ activeEdges'  = RemoveVertices(activeEdges, {v})
  /\ pendingEdges' = RemoveVertices(pendingEdges, {v})
  /\ detected'     = detected \ {v}
  /\ UNCHANGED <<phase, period, round, dfsStack,
                 stage0Visited, lclv, puid>>

\* Start next periodic detection cycle (resets PuID to PrID, Section 4.6).
AsyncNextPeriod ==
  /\ phase = "Spread"
  /\ detected = {}
  /\ period < MaxPeriods
  /\ activeEdges # {}
  /\ period'        = period + 1
  /\ phase'         = IF EnableStage0 THEN "Stage0" ELSE "Prolif"
  /\ round'         = 1
  /\ pendingEdges'  = IF EnableStage0 THEN {} ELSE activeEdges
  /\ dfsStack'      = << >>
  /\ stage0Visited' = {}
  /\ puid'          = [v \in Vertex |-> v]
  /\ UNCHANGED <<activeEdges, lclv, detected, killed>>

Next ==
  \/ \E u \in Vertex : Stage0Start(u, FALSE)
  \/ \E b \in Vertex : Stage0DetectLocalCycle(b)
  \/ \E b \in Vertex : Stage0AdvanceLocal(b, TRUE)
  \/ \E b \in Vertex : Stage0PushRemote(b, TRUE)
  \/ Stage0StopWalk
  \/ FinishStage0(FALSE)
  \/ \E e \in activeEdges : AsyncProlifEdge(e)
  \/ AsyncProlifToSpread
  \/ \E e \in activeEdges : AsyncSpreadEdge(e)
  \/ \E v \in detected    : AsyncAbortVictim(v)
  \/ AsyncNextPeriod

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Round-Complete Deduction Model Actions (RoundSpec / LiveSpec, Sec 4-5)  *)

\* Definition 4.8 & 4.10: apply proliferation on each edge in arbitrary order per round.
RoundProlifEdge(e) ==
  /\ phase = "Prolif"
  /\ e \in pendingEdges
  /\ lclv'         = [lclv EXCEPT ![e[2]] = Max(@, lclv[e[1]] + 1)]
  /\ pendingEdges' = pendingEdges \ {e}
  /\ UNCHANGED <<activeEdges, phase, period, round, dfsStack,
                 stage0Visited, puid, detected, killed>>

AdvanceProlifRound ==
  /\ phase = "Prolif"
  /\ pendingEdges = {}
  /\ IF round < ProlifRounds
     THEN /\ round'        = round + 1
          /\ pendingEdges' = activeEdges
          /\ UNCHANGED <<activeEdges, phase, period, dfsStack,
                         stage0Visited, lclv, puid, detected, killed>>
     ELSE /\ IF SpreadRounds > 0
             THEN /\ phase'        = "Spread"
                  /\ round'        = 1
                  /\ pendingEdges' = activeEdges
                  /\ UNCHANGED <<detected>>
             ELSE /\ phase'        = "Detect"
                  /\ round'        = 0
                  /\ pendingEdges' = {}
                  /\ detected'     = {v \in Vertex :
                                        \E u \in Vertex :
                                          /\ <<u, v>> \in activeEdges
                                          /\ DetectsOnEdge(u, v, lclv, puid)}
          /\ UNCHANGED <<activeEdges, period, dfsStack,
                         stage0Visited, lclv, puid, killed>>

\* Definition 4.9 & 4.10: apply spread on each edge in arbitrary order per round.
RoundSpreadEdge(e) ==
  /\ phase = "Spread"
  /\ e \in pendingEdges
  /\ LET u == e[1]
         v == e[2]
     IN /\ lclv'         = [lclv EXCEPT ![v] = SpreadLCLV(u, v)]
        /\ puid'         = [puid EXCEPT ![v] = SpreadPuID(u, v)]
        /\ pendingEdges' = pendingEdges \ {e}
        /\ UNCHANGED <<activeEdges, phase, period, round, dfsStack,
                       stage0Visited, detected, killed>>

AdvanceSpreadRound ==
  /\ phase = "Spread"
  /\ pendingEdges = {}
  /\ IF round < SpreadRounds
     THEN /\ round'        = round + 1
          /\ pendingEdges' = activeEdges
          /\ UNCHANGED <<activeEdges, phase, period, dfsStack,
                         stage0Visited, lclv, puid, detected, killed>>
     ELSE /\ phase'        = "Detect"
          /\ round'        = 0
          /\ pendingEdges' = {}
          /\ detected'     = {v \in Vertex :
                                \E u \in Vertex :
                                  /\ <<u, v>> \in activeEdges
                                  /\ DetectsOnEdge(u, v, lclv, puid)}
          /\ UNCHANGED <<activeEdges, period, dfsStack,
                         stage0Visited, lclv, puid, killed>>

\* Terminate all victims detected in Stage 3; if cycles remain, start next period.
ResolvePeriod ==
  /\ phase = "Detect"
  /\ LET newKilled == killed \cup detected
         remEdges  == RemoveVertices(activeEdges, detected)
     IN /\ killed'       = newKilled
        /\ activeEdges'  = remEdges
        /\ detected'     = {}
        /\ puid'         = [v \in Vertex |-> v]
        /\ dfsStack'     = << >>
        /\ stage0Visited' = {}
        /\ IF AllNontrivialSCCs(remEdges) = {}
           THEN /\ phase'        = "Done"
                /\ round'        = 0
                /\ pendingEdges' = {}
                /\ UNCHANGED <<period, lclv>>
           ELSE /\ period'       = period + 1
                /\ phase'        = IF EnableStage0 THEN "Stage0" ELSE "Prolif"
                /\ round'        = 1
                /\ pendingEdges' = IF EnableStage0 THEN {} ELSE remEdges
                /\ UNCHANGED <<lclv>>

RoundNext ==
  \/ \E u \in Vertex : Stage0Start(u, TRUE)
  \/ \E b \in Vertex : Stage0DetectLocalCycle(b)
  \/ \E b \in Vertex : Stage0AdvanceLocal(b, FALSE)
  \/ \E b \in Vertex : Stage0PushRemote(b, FALSE)
  \/ Stage0StopWalk
  \/ FinishStage0(TRUE)
  \/ \E e \in activeEdges : RoundProlifEdge(e)
  \/ AdvanceProlifRound
  \/ \E e \in activeEdges : RoundSpreadEdge(e)
  \/ AdvanceSpreadRound
  \/ ResolvePeriod

RoundSpec == Init /\ [][RoundNext]_vars

Fairness ==
  /\ \A u \in Vertex : WF_vars(Stage0Start(u, TRUE))
  /\ \A b \in Vertex :
       /\ WF_vars(Stage0DetectLocalCycle(b))
       /\ WF_vars(Stage0AdvanceLocal(b, FALSE))
       /\ WF_vars(Stage0PushRemote(b, FALSE))
  /\ WF_vars(Stage0StopWalk)
  /\ WF_vars(FinishStage0(TRUE))
  /\ \A e \in Edges :
       /\ WF_vars(RoundProlifEdge(e))
       /\ WF_vars(RoundSpreadEdge(e))
  /\ WF_vars(AdvanceProlifRound)
  /\ WF_vars(AdvanceSpreadRound)
  /\ WF_vars(ResolvePeriod)

LiveSpec == RoundSpec /\ Fairness

-----------------------------------------------------------------------------
(* Safety Invariants and Temporal Properties                               *)

TypeOK ==
  /\ activeEdges \subseteq Edges
  /\ phase \in {"Stage0", "Prolif", "Spread", "Detect", "Done"}
  /\ period \in Nat \ {0}
  /\ round \in Nat
  /\ pendingEdges \subseteq activeEdges
  /\ SeqElems(dfsStack) \subseteq Vertex
  /\ stage0Visited \subseteq Vertex
  /\ lclv \in [Vertex -> Nat]
  /\ puid \in [Vertex -> Vertex]
  /\ detected \subseteq Vertex
  /\ killed \subseteq Vertex

\* Token Origin Invariant: every vertex's PuID originated at an ancestor in Edges
\* with AP (PrID) at least its own.
TokenOriginValid ==
  \A x \in Vertex :
    /\ puid[x] >= x
    /\ x \in Reachable(Edges, puid[x])

\* Soundness / No Manslaughter (Section 5.1.1):
\* No transaction outside a genuine deadlock cycle in Edges is ever detected or killed.
NoManslaughter ==
  \A v \in (detected \cup killed) : InCycle(Edges, v)

\* Stronger Cycle-Witness Invariant: every detected or killed vertex is the strict
\* maximum-AP vertex of at least one simple cycle in the initial WFG Edges.
ValidCycleVictim ==
  \A v \in (detected \cup killed) :
    \E c \in AllSimpleCycles(Edges) :
      /\ v \in SeqElems(c)
      /\ SetMax(SeqElems(c)) = v

\* No Multi-Kill Bound (Section 5.1.1): in a view with N simple deadlock cycles,
\* at most N vertices are ever killed across the entire execution.
BoundedTotalVictims ==
  Cardinality(detected \cup killed) <= InitialSimpleCycleCount

\* Clean Victim Cleanup: no vertex is detected after already being killed, and
\* killed vertices hold no active edges.
NoVictimKilledTwice ==
  /\ detected \cap killed = {}
  /\ \A e \in activeEdges : e[1] \notin killed /\ e[2] \notin killed

\* Monotonicity of LCLV across all transitions, and of PuID within Spread.
LCLVMonotonic ==
  [][\A v \in Vertex : lclv'[v] >= lclv[v]]_vars

PuIDMonotonicInSpread ==
  [][(phase = "Spread" /\ phase' = "Spread") =>
       \A v \in Vertex : puid'[v] >= puid[v]]_vars

\* Theorem 5.5: whenever a nontrivial SCC exists, at least one topmost SCC exists.
TopmostSCCExists ==
  (AllNontrivialSCCs(activeEdges) # {}) => (TopmostSCCs(activeEdges) # {})

\* Lemma 5.10(ii)-(iii) (checked under RoundSpec / LiveSpec):
\* Once Proliferation finishes (throughout Spread and Detect), for every topmost SCC,
\* every edge from ASG(scc) into USG(scc) satisfies u.LCLV < v.LCLV, and
\* max{ASG(scc).LCLV} < max{scc.LCLV}.
AnnulusIsolation ==
  (phase \in {"Spread", "Detect"}) =>
    \A scc \in TopmostSCCs(activeEdges) :
      /\ \A u \in ASG(activeEdges, scc), v \in USG(activeEdges, scc) :
           <<u, v>> \in activeEdges => lclv[u] < lclv[v]
      /\ \A u \in ASG(activeEdges, scc) :
           \E w \in scc : lclv[u] < lclv[w]

\* Theorem 5.11 (checked under RoundSpec / LiveSpec):
\* At Stage 3 Detection, in USG(scc) of every topmost SCC scc, there is a unique
\* detected victim B, and B is the maximum-AP vertex of scc.
TopmostSCCUniqueVictim ==
  (phase = "Detect") =>
    \A scc \in TopmostSCCs(activeEdges) :
      detected \cap USG(activeEdges, scc) = {SetMax(scc)}

\* Liveness (Section 5.1.2, checked under LiveSpec):
\* Every deadlock cycle in the WFG is eventually detected and broken.
EventuallyDeadlockFree ==
  <>([](AllNontrivialSCCs(activeEdges) = {}))

-----------------------------------------------------------------------------
(* Reachability Witnesses (each invariant is VIOLATED when path is reached) *)

\* Stage 0 (LCL+) immediately detects a local cycle on a single server.
NoStage0LocalDetect ==
  ~(phase = "Stage0" /\ detected # {})

\* Stage 0 (LCL+) pre-proliferates LCLV across a local edge into a remote vertex.
NoStage0RemotePush ==
  ~(phase = "Stage0" /\ \E u, v \in Vertex :
      <<u, v>> \in Edges /\ ServerOf[u] # ServerOf[v] /\ lclv[v] > 0)

\* High-AP annulus upstream node is blocked from polluting a topmost SCC.
NoAnnulusHighAPBlocked ==
  ~(phase = "Detect" /\ detected # {} /\
    \E scc \in TopmostSCCs(activeEdges) :
      \E u \in ASG(activeEdges, scc) : u > SetMax(scc))

\* Distributed cycle is detected in Stage 3 / Spread and resolved cleanly.
NoDeadlockResolved ==
  ~(AllNontrivialSCCs(Edges) # {} /\ AllNontrivialSCCs(activeEdges) = {})

\* Chained SCCs (Figure 17(b)) resolve across two successive periods.
NoChainedMultiPeriod ==
  ~(period >= 2 /\ Cardinality(killed) = 2 /\ AllNontrivialSCCs(activeEdges) = {})

\* Asynchronous concurrent mid-Spread resolution on a multi-cycle SCC kills two
\* cycle-max victims (still <= N = 2 cycles), distinguishing Section 4.6 from Algorithm 1.
NoAsyncTwoVictimsInOneSCC ==
  ~(Cardinality(AllNontrivialSCCs(Edges)) = 1 /\ Cardinality(killed) = 2)

=============================================================================
