------------------------------ MODULE Tree2PC ------------------------------
(***************************************************************************)
(* Dynamic Tree-Structured Two-Phase Commit (2PC) over OceanBase log       *)
(* streams with live partition transfers, circular topologies, and         *)
(* unknown-state recovery (TCT/TDT, prepare_unknown, trans_unknown).       *)
(*                                                                         *)
(* Grounded in "A Tree-Structured Two-Phase Commit Framework for           *)
(* OceanBase: Optimizing Scalability and Consistency" (PVLDB 19(12),       *)
(* DOI: 10.14778/3827998.3828030, Sections 2.2-2.3, 3.3, 4.1-4.6, 5.1-5.3, *)
(* and 6.2, Algorithms 1-3) and OceanBase src/storage/tx.                  *)
(*                                                                         *)
(* Key protocol mechanisms modeled:                                        *)
(*  - Coalesced log-stream participants arranged in a coordinator-rooted   *)
(*    commit graph where each interior node acts uniformly as coordinator  *)
(*    to its children and participant to its first preparing parent.       *)
(*  - Three participant sets per transaction context (Section 4.2):        *)
(*    SQL-layer `parts`, durable merged transfer set `incr`, and current-  *)
(*    stage staging set `interm` merged only at phase boundaries.          *)
(*  - Lock-synchronized non-atomic partition transfer (Section 4.3,        *)
(*    Algorithms 2 and 3): `BeginTransfer` blocks phase-log commits on the *)
(*    source under `lock_t` and snapshots pre-transfer state;              *)
(*    `CommitTransferLogs` commits transfer-out/transfer-in and migrates   *)
(*    logged state to the destination (Theorem 4.1); `FinishTransfer`      *)
(*    records `dst` in `interm` and unblocks log commits (Theorem 4.3).    *)
(*  - Circular transaction rule (Section 4.6): a prepared stream replies   *)
(*    `ok` immediately to secondary parents (`src # parent[n]`) without    *)
(*    waiting on downstream children, avoiding cycle deadlocks while the   *)
(*    first-parent arborescence preserves subtree vote completeness.       *)
(*  - Context reclamation, TDT retention, and unknown-state fallback       *)
(*    (Sections 5.1-5.3): `ForgetCtx` reclaims active TCT (`TOMBSTONE`)    *)
(*    while TDT retains terminal outcomes until `EvictTDT`. Without TCT or *)
(*    TDT, participants reply `prep_unknown`; newly created coordinators   *)
(*    return `ABORT`, whereas recreated coordinators on client retry       *)
(*    return `TRANS_UNKNOWN` rather than fabricating `COMMIT` or `ABORT`.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Root,              \* root coordinator log stream
  SubCoord,          \* initial tier-1 sub-coordinator log streams under Root
  DirectLeaf,        \* initial tier-1 leaf log streams directly under Root
  SubLeaf,           \* initial tier-2 leaf log streams under each SubCoord
  IdleLS,            \* initially uninvolved log streams (fresh transfer targets)
  HostedInit,        \* subset of initial active streams hosting partitions
  None,              \* model value: absent parent or no transfer in flight
  MaxTransfers,      \* bound on partition transfers
  AllowContextLoss,  \* BOOLEAN: allow volatile RUNNING context loss before Prepare
  AllowTDTEvict,     \* BOOLEAN: allow TDT eviction after ForgetCtx (TOMBSTONE)
  AllowRetry         \* BOOLEAN: allow lost client reply and coordinator retry

LS == {Root} \cup SubCoord \cup DirectLeaf \cup SubLeaf \cup IdleLS

Part == HostedInit

InitActive == {Root} \cup SubCoord \cup DirectLeaf \cup SubLeaf

ASSUME /\ None \notin LS
       /\ Root \notin (SubCoord \cup DirectLeaf \cup SubLeaf \cup IdleLS)
       /\ SubCoord \cap (DirectLeaf \cup SubLeaf \cup IdleLS) = {}
       /\ DirectLeaf \cap (SubLeaf \cup IdleLS) = {}
       /\ SubLeaf \cap IdleLS = {}
       /\ Cardinality(SubCoord) <= 1
       /\ (SubLeaf # {}) => (SubCoord # {})
       /\ HostedInit \subseteq InitActive
       /\ HostedInit # {}
       /\ MaxTransfers \in Nat
       /\ AllowContextLoss \in BOOLEAN
       /\ AllowTDTEvict \in BOOLEAN
       /\ AllowRetry \in BOOLEAN

VARIABLES
  \* Transaction Context Table (TCT) per log stream
  state,          \* [LS -> {"IDLE","RUNNING","PREPARE","COMMIT","ABORT","TOMBSTONE"}]
  parent,         \* [LS -> LS \cup {None}] first parent that prepared or finalized n
  parts,          \* [LS -> SUBSET LS] initial SQL-layer participant set
  incr,           \* [LS -> SUBSET LS] durable merged transfer participant set
  interm,         \* [LS -> SUBSET LS] in-stage transfer targets awaiting phase merge
  votes,          \* [LS -> [children -> {"unknown","ok","no","prep_unknown"}]]
  acks,           \* [LS -> [children -> BOOLEAN]]
  votedUp,        \* [LS -> BOOLEAN] whether non-root n already sent its upward vote
  fromRunning,    \* [LS -> BOOLEAN] history: whether n entered PREPARE from RUNNING
  blocked,        \* [LS -> BOOLEAN] Algorithm 2 log-commit block under lock_t
  \* Transaction Data Table (TDT) and ground-truth outcome history
  tdt,            \* [LS -> {"none","COMMIT","ABORT"}] bounded-retention terminal table
  decision,       \* [LS -> {"none","COMMIT","ABORT"}] durable terminal history
  \* Partition placement and in-flight transfer state (Algorithms 2-3)
  host,           \* [Part -> LS] current hosting log stream of each partition
  inFlightXfer,   \* None or [phase, part, src, dst, snapState, snapDec]
  transfersUsed,  \* 0..MaxTransfers
  \* Asynchronous network and client/retry boundary (Section 5)
  msgs,           \* SUBSET Message: asynchronous message bag (duplicates/reorderings)
  clientState,    \* {"WAITING", "LOST", "PROBING", "DONE"}
  retryVotes,     \* [parts[Root] -> {"pending","ok_tct","ok_tdt","no","prep_unknown"}]
  clientResp      \* {"PENDING", "COMMIT", "ABORT", "TRANS_UNKNOWN"}

vars == <<state, parent, parts, incr, interm, votes, acks, votedUp,
          fromRunning, blocked, tdt, decision, host, inFlightXfer,
          transfersUsed, msgs, clientState, retryVotes, clientResp>>

-----------------------------------------------------------------------------
(* Helpers *)

States == {"IDLE", "RUNNING", "PREPARE", "COMMIT", "ABORT", "TOMBSTONE"}

IsRoot(n) == n = Root

Children(n) == parts[n] \cup incr[n]

MergedIncr(n) == incr[n] \cup interm[n]

MergedChildren(n) == parts[n] \cup MergedIncr(n)

MsgPrepareReq(src, dst) ==
  [type |-> "PrepareReq", src |-> src, dst |-> dst]

MsgPrepareResp(src, dst, status) ==
  [type |-> "PrepareResp", src |-> src, dst |-> dst, status |-> status]

MsgCommit(src, dst) ==
  [type |-> "Commit", src |-> src, dst |-> dst]

MsgAbort(src, dst) ==
  [type |-> "Abort", src |-> src, dst |-> dst]

MsgAck(src, dst) ==
  [type |-> "Ack", src |-> src, dst |-> dst]

AllVotesOk(n) ==
  \A c \in Children(n) : votes[n][c] = "ok"

HasNegativeVote(n) ==
  \E c \in Children(n) : votes[n][c] \in {"no", "prep_unknown"}

UpwardAbortStatus(n) ==
  IF \E c \in Children(n) : votes[n][c] = "prep_unknown"
  THEN "prep_unknown"
  ELSE "no"

AllAcked(n) ==
  \A c \in Children(n) : acks[n][c] = TRUE

RecordParent(n, src) ==
  IF IsRoot(n) \/ parent[n] # None THEN parent[n] ELSE src

\* Algorithm 3 (LogCommit): merge interm into incr when persisting a 2PC phase log.
ApplyMerge(n) ==
  /\ incr'   = [incr EXCEPT ![n] = MergedIncr(n)]
  /\ interm' = [interm EXCEPT ![n] = {}]

StateRank(s) ==
  CASE s = "IDLE"      -> 0
    [] s = "RUNNING"   -> 1
    [] s = "PREPARE"   -> 2
    [] s = "COMMIT"    -> 3
    [] s = "ABORT"     -> 3
    [] s = "TOMBSTONE" -> 4

\* Graph reachability over directed edges E \subseteq LS \X LS.
RECURSIVE ReachSteps(_, _, _)
ReachSteps(E, S, k) ==
  IF k = 0
  THEN S
  ELSE LET nxt == S \cup {v \in LS : \E u \in S : <<u, v>> \in E}
       IN IF nxt = S THEN S ELSE ReachSteps(E, nxt, k - 1)

Reachable(E, src) == ReachSteps(E, {src}, Cardinality(LS))

ActiveEdges ==
  {<<u, v>> \in LS \X LS : v \in parts[u] \cup incr[u] \cup interm[u]}

CommittedEdges ==
  {<<u, v>> \in LS \X LS : v \in Children(u)}

SymGroup(S) ==
  Permutations(S \cap HostedInit) \cup Permutations(S \ HostedInit)

Symmetry ==
  SymGroup(DirectLeaf) \cup SymGroup(SubLeaf) \cup Permutations(IdleLS)

-----------------------------------------------------------------------------
(* Initial state *)

InitParts(n) ==
  IF n = Root THEN SubCoord \cup DirectLeaf
  ELSE IF n \in SubCoord THEN SubLeaf
  ELSE {}

Init ==
  /\ state         = [n \in LS |-> IF n \in InitActive THEN "RUNNING" ELSE "IDLE"]
  /\ parent        = [n \in LS |-> None]
  /\ parts         = [n \in LS |-> InitParts(n)]
  /\ incr          = [n \in LS |-> {}]
  /\ interm        = [n \in LS |-> {}]
  /\ votes         = [n \in LS |-> [c \in InitParts(n) |-> "unknown"]]
  /\ acks          = [n \in LS |-> [c \in InitParts(n) |-> FALSE]]
  /\ votedUp       = [n \in LS |-> FALSE]
  /\ fromRunning   = [n \in LS |-> FALSE]
  /\ blocked       = [n \in LS |-> FALSE]
  /\ tdt           = [n \in LS |-> "none"]
  /\ decision      = [n \in LS |-> "none"]
  /\ host          = [p \in Part |-> p]
  /\ inFlightXfer  = None
  /\ transfersUsed = 0
  /\ msgs          = {}
  /\ clientState   = "WAITING"
  /\ retryVotes    = [c \in InitParts(Root) |-> "pending"]
  /\ clientResp    = "PENDING"

-----------------------------------------------------------------------------
(* Phase 1: Prepare and Circular Duplicate-Prepare Handling (Sections 3.3, 4.6) *)

RootStartToCommit ==
  /\ state[Root] = "RUNNING"
  /\ ~blocked[Root]
  /\ LET mc == MergedChildren(Root) IN
     /\ state'       = [state EXCEPT ![Root] = "PREPARE"]
     /\ fromRunning' = [fromRunning EXCEPT ![Root] = TRUE]
     /\ ApplyMerge(Root)
     /\ votes'       = [votes EXCEPT ![Root] = [c \in mc |-> "unknown"]]
     /\ msgs'        = msgs \cup {MsgPrepareReq(Root, c) : c \in mc}
     /\ UNCHANGED <<parent, parts, acks, votedUp, blocked, tdt, decision,
                    host, inFlightXfer, transfersUsed, clientState,
                    retryVotes, clientResp>>

Handle2pcPrepareRequest(n) ==
  /\ ~IsRoot(n)
  /\ state[n] = "RUNNING"
  /\ ~blocked[n]
  /\ \E m \in msgs :
       /\ m.type = "PrepareReq"
       /\ m.dst = n
       /\ LET mc == MergedChildren(n) IN
          /\ parent'      = [parent EXCEPT ![n] = m.src]
          /\ state'       = [state EXCEPT ![n] = "PREPARE"]
          /\ fromRunning' = [fromRunning EXCEPT ![n] = TRUE]
          /\ ApplyMerge(n)
          /\ votes'       = [votes EXCEPT ![n] = [c \in mc |-> "unknown"]]
          /\ msgs'        = msgs \cup {MsgPrepareReq(n, c) : c \in mc}
          /\ UNCHANGED <<parts, acks, votedUp, blocked, tdt, decision,
                         host, inFlightXfer, transfersUsed, clientState,
                         retryVotes, clientResp>>

\* Section 4.6: Once local prepare log has persisted (state[n] \in {"PREPARE","COMMIT"}),
\* a PrepareReq from any secondary parent (m.src # parent[n]) immediately receives "ok"
\* without waiting on downstream children, preventing circular deadlocks.
Handle2pcDuplicatePrepareRequest(n) ==
  /\ state[n] \in {"PREPARE", "COMMIT"}
  /\ \E m \in msgs :
       /\ m.type = "PrepareReq"
       /\ m.dst = n
       /\ m.src # parent[n]
       /\ MsgPrepareResp(n, m.src, "ok") \notin msgs
       /\ msgs' = msgs \cup {MsgPrepareResp(n, m.src, "ok")}
       /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks,
                      votedUp, fromRunning, blocked, tdt, decision, host,
                      inFlightXfer, transfersUsed, clientState, retryVotes,
                      clientResp>>

\* Section 5.2-5.3: Late/orphan PrepareReq arriving after ABORT or TOMBSTONE.
\* Answers from active ABORT or retained TDT if present; otherwise replies
\* "prep_unknown" instead of fabricating "ok" or "no".
HandleOrphan2pcPrepareRequest(n) ==
  /\ state[n] \in {"ABORT", "TOMBSTONE"}
  /\ \E m \in msgs :
       /\ m.type = "PrepareReq"
       /\ m.dst = n
       /\ LET status == IF state[n] = "ABORT" \/ tdt[n] = "ABORT" THEN "no"
                        ELSE IF tdt[n] = "COMMIT" THEN "ok"
                        ELSE "prep_unknown"
          IN /\ MsgPrepareResp(n, m.src, status) \notin msgs
             /\ parent' = [parent EXCEPT ![n] = RecordParent(n, m.src)]
             /\ msgs'   = msgs \cup {MsgPrepareResp(n, m.src, status)}
             /\ UNCHANGED <<state, parts, incr, interm, votes, acks,
                            votedUp, fromRunning, blocked, tdt, decision,
                            host, inFlightXfer, transfersUsed, clientState,
                            retryVotes, clientResp>>

-----------------------------------------------------------------------------
(* Phase 2 & 3: Vote Collection and Subtree / Root Decision *)

Handle2pcPrepareResponse(n) ==
  /\ state[n] = "PREPARE"
  /\ \E m \in msgs :
       /\ m.type = "PrepareResp"
       /\ m.dst = n
       /\ m.src \in Children(n)
       /\ votes[n][m.src] = "unknown"
       /\ votes' = [votes EXCEPT ![n][m.src] = m.status]
       /\ UNCHANGED <<state, parent, parts, incr, interm, acks, votedUp,
                      fromRunning, blocked, tdt, decision, host, inFlightXfer,
                      transfersUsed, msgs, clientState, retryVotes, clientResp>>

Handle2pcCommitDecided(n) ==
  /\ state[n] = "PREPARE"
  /\ AllVotesOk(n)
  /\ IF IsRoot(n)
     THEN /\ ~blocked[n]
          /\ LET mc == MergedChildren(n) IN
             /\ state'    = [state EXCEPT ![n] = "COMMIT"]
             /\ decision' = [decision EXCEPT ![n] = "COMMIT"]
             /\ tdt'      = [tdt EXCEPT ![n] = "COMMIT"]
             /\ ApplyMerge(n)
             /\ acks'     = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
             /\ msgs'     = msgs \cup {MsgCommit(n, c) : c \in mc}
             /\ UNCHANGED <<parent, parts, votes, votedUp, fromRunning,
                            blocked, host, inFlightXfer, transfersUsed,
                            clientState, retryVotes, clientResp>>
     ELSE /\ ~votedUp[n]
          /\ parent[n] # None
          /\ votedUp' = [votedUp EXCEPT ![n] = TRUE]
          /\ msgs'    = msgs \cup {MsgPrepareResp(n, parent[n], "ok")}
          /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks,
                         fromRunning, blocked, tdt, decision, host,
                         inFlightXfer, transfersUsed, clientState,
                         retryVotes, clientResp>>

Handle2pcAbortDecided(n) ==
  /\ state[n] = "PREPARE"
  /\ HasNegativeVote(n)
  /\ IF IsRoot(n)
     THEN /\ ~blocked[n]
          /\ LET mc == MergedChildren(n) IN
             /\ state'    = [state EXCEPT ![n] = "ABORT"]
             /\ decision' = [decision EXCEPT ![n] = "ABORT"]
             /\ tdt'      = [tdt EXCEPT ![n] = "ABORT"]
             /\ ApplyMerge(n)
             /\ acks'     = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
             /\ msgs'     = msgs \cup {MsgAbort(n, c) : c \in mc}
             /\ UNCHANGED <<parent, parts, votes, votedUp, fromRunning,
                            blocked, host, inFlightXfer, transfersUsed,
                            clientState, retryVotes, clientResp>>
     ELSE /\ ~votedUp[n]
          /\ parent[n] # None
          /\ votedUp' = [votedUp EXCEPT ![n] = TRUE]
          /\ msgs'    = msgs \cup {MsgPrepareResp(n, parent[n], UpwardAbortStatus(n))}
          /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks,
                         fromRunning, blocked, tdt, decision, host,
                         inFlightXfer, transfersUsed, clientState,
                         retryVotes, clientResp>>

-----------------------------------------------------------------------------
(* Phase 4 & 5: Decision Propagation, Abnormal Flow, Ack & Reclamation *)

Handle2pcCommitRequest(n) ==
  /\ ~IsRoot(n)
  /\ state[n] \in {"RUNNING", "PREPARE"}
  /\ ~blocked[n]
  /\ \E m \in msgs :
       /\ m.type = "Commit"
       /\ m.dst = n
       /\ LET mc == MergedChildren(n) IN
          /\ parent'   = [parent EXCEPT ![n] = RecordParent(n, m.src)]
          /\ state'    = [state EXCEPT ![n] = "COMMIT"]
          /\ decision' = [decision EXCEPT ![n] = "COMMIT"]
          /\ tdt'      = [tdt EXCEPT ![n] = "COMMIT"]
          /\ ApplyMerge(n)
          /\ acks'     = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
          /\ msgs'     = msgs \cup {MsgCommit(n, c) : c \in mc}
                              \cup {MsgAck(n, m.src)}
          /\ UNCHANGED <<parts, votes, votedUp, fromRunning, blocked, host,
                         inFlightXfer, transfersUsed, clientState,
                         retryVotes, clientResp>>

Handle2pcAbortRequest(n) ==
  /\ state[n] \in {"RUNNING", "PREPARE"}
  /\ ~blocked[n]
  /\ \E m \in msgs :
       /\ m.type = "Abort"
       /\ m.dst = n
       /\ LET mc == MergedChildren(n) IN
          /\ parent'   = [parent EXCEPT ![n] = RecordParent(n, m.src)]
          /\ state'    = [state EXCEPT ![n] = "ABORT"]
          /\ decision' = [decision EXCEPT ![n] = "ABORT"]
          /\ tdt'      = [tdt EXCEPT ![n] = "ABORT"]
          /\ ApplyMerge(n)
          /\ acks'     = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
          /\ msgs'     = msgs \cup {MsgAbort(n, c) : c \in mc}
                              \cup {MsgAck(n, m.src)}
          /\ UNCHANGED <<parts, votes, votedUp, fromRunning, blocked, host,
                         inFlightXfer, transfersUsed, clientState,
                         retryVotes, clientResp>>

HandleOrphan2pcCommitRequest(n) ==
  /\ state[n] \in {"COMMIT", "TOMBSTONE"}
  /\ \E m \in msgs :
       /\ m.type = "Commit"
       /\ m.dst = n
       /\ MsgAck(n, m.src) \notin msgs
       /\ msgs' = msgs \cup {MsgAck(n, m.src)}
       /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks,
                      votedUp, fromRunning, blocked, tdt, decision, host,
                      inFlightXfer, transfersUsed, clientState, retryVotes,
                      clientResp>>

HandleOrphan2pcAbortRequest(n) ==
  /\ state[n] \in {"ABORT", "TOMBSTONE"}
  /\ \E m \in msgs :
       /\ m.type = "Abort"
       /\ m.dst = n
       /\ MsgAck(n, m.src) \notin msgs
       /\ msgs' = msgs \cup {MsgAck(n, m.src)}
       /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks,
                      votedUp, fromRunning, blocked, tdt, decision, host,
                      inFlightXfer, transfersUsed, clientState, retryVotes,
                      clientResp>>

InternalAbort(n) ==
  /\ state[n] = "RUNNING"
  /\ ~blocked[n]
  /\ LET mc == MergedChildren(n)
         parentNotify == IF parent[n] # None
                         THEN {MsgPrepareResp(n, parent[n], "no")}
                         ELSE {}
     IN /\ state'    = [state EXCEPT ![n] = "ABORT"]
        /\ decision' = [decision EXCEPT ![n] = "ABORT"]
        /\ tdt'      = [tdt EXCEPT ![n] = "ABORT"]
        /\ ApplyMerge(n)
        /\ acks'     = [acks EXCEPT ![n] = [c \in mc |-> FALSE]]
        /\ msgs'     = msgs \cup {MsgAbort(n, c) : c \in mc} \cup parentNotify
        /\ UNCHANGED <<parent, parts, votes, votedUp, fromRunning, blocked,
                       host, inFlightXfer, transfersUsed, clientState,
                       retryVotes, clientResp>>

\* Section 5.2 (newly created coordinator encountering prepare_unknown):
\* A leaf stream in RUNNING loses its volatile uncommitted TCT before writing
\* any 2PC prepare/abort log (so TDT has no entry for it).
DropRunningCtx(n) ==
  /\ AllowContextLoss
  /\ ~IsRoot(n)
  /\ state[n] = "RUNNING"
  /\ ~blocked[n]
  /\ parts[n] = {}
  /\ incr[n] = {}
  /\ interm[n] = {}
  /\ state'    = [state EXCEPT ![n] = "TOMBSTONE"]
  /\ decision' = [decision EXCEPT ![n] = "ABORT"]
  /\ UNCHANGED <<parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, host, inFlightXfer,
                 transfersUsed, msgs, clientState, retryVotes, clientResp>>

Handle2pcAckResponse(n) ==
  /\ state[n] \in {"COMMIT", "ABORT"}
  /\ \E m \in msgs :
       /\ m.type = "Ack"
       /\ m.dst = n
       /\ m.src \in Children(n)
       /\ acks[n][m.src] = FALSE
       /\ acks' = [acks EXCEPT ![n][m.src] = TRUE]
       /\ UNCHANGED <<state, parent, parts, incr, interm, votes, votedUp,
                      fromRunning, blocked, tdt, decision, host, inFlightXfer,
                      transfersUsed, msgs, clientState, retryVotes, clientResp>>

ForgetCtx(n) ==
  /\ state[n] \in {"COMMIT", "ABORT"}
  /\ ~blocked[n]
  /\ AllAcked(n)
  /\ state' = [state EXCEPT ![n] = "TOMBSTONE"]
  /\ UNCHANGED <<parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs, clientState, retryVotes, clientResp>>

-----------------------------------------------------------------------------
(* Lock-Synchronized Partition Transfer (Sections 4.1-4.3, Algorithms 1-3) *)

\* Algorithm 2 lines 1-8: under lock_t on src = host[p], block src from writing
\* new 2PC logs and collect src's pre-transfer transaction context.
BeginTransfer(p, dst) ==
  /\ transfersUsed < MaxTransfers
  /\ inFlightXfer = None
  /\ LET src == host[p] IN
     /\ dst # src
     /\ state[src] \in {"RUNNING", "PREPARE", "COMMIT", "ABORT"}
     /\ ~blocked[src]
     /\ blocked'       = [blocked EXCEPT ![src] = TRUE]
     /\ inFlightXfer'  = [phase     |-> "Blocked",
                          part      |-> p,
                          src       |-> src,
                          dst       |-> dst,
                          snapState |-> state[src],
                          snapDec   |-> decision[src]]
     /\ transfersUsed' = transfersUsed + 1
     /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                    fromRunning, tdt, decision, host, msgs, clientState,
                    retryVotes, clientResp>>

\* Algorithm 2 lines 9-10 & Theorem 4.1 (MigrateData): commit transfer-out on src
\* and transfer-in on dst, migrating pre-transfer context to dst with monotonic
\* destination-wins merging (Section 5.3).
CommitTransferLogs ==
  /\ inFlightXfer # None
  /\ inFlightXfer.phase = "Blocked"
  /\ LET p    == inFlightXfer.part
         src  == inFlightXfer.src
         dst  == inFlightXfer.dst
         sSt  == inFlightXfer.snapState
         sDec == inFlightXfer.snapDec
     IN /\ host' = [host EXCEPT ![p] = dst]
        /\ inFlightXfer' = [inFlightXfer EXCEPT !.phase = "Committed"]
        /\ CASE \* Terminal source decision (COMMIT or ABORT) migrates to dst
                (sDec \in {"COMMIT", "ABORT"} /\ state[dst] \in {"IDLE", "RUNNING", "PREPARE"}) ->
                  LET mc      == MergedChildren(dst)
                      downMsg == IF sDec = "COMMIT"
                                 THEN {MsgCommit(dst, c) : c \in mc}
                                 ELSE {MsgAbort(dst, c) : c \in mc}
                  IN /\ state'    = [state EXCEPT ![dst] = sDec]
                     /\ decision' = [decision EXCEPT ![dst] = sDec]
                     /\ tdt'      = [tdt EXCEPT ![dst] = sDec]
                     /\ parent'   = [parent EXCEPT ![dst] = RecordParent(dst, src)]
                     /\ ApplyMerge(dst)
                     /\ acks'     = [acks EXCEPT ![dst] = [c \in mc |-> FALSE]]
                     /\ msgs'     = msgs \cup downMsg
                     /\ UNCHANGED <<votes, votedUp, fromRunning>>
             \* Source in PREPARE and dst was IDLE: dst adopts PREPARE directly
             [] (sDec = "none" /\ sSt = "PREPARE" /\ state[dst] = "IDLE") ->
                  /\ state'   = [state EXCEPT ![dst] = "PREPARE"]
                  /\ parent'  = [parent EXCEPT ![dst] = src]
                  /\ votes'   = [votes EXCEPT ![dst] = [c \in {} |-> "unknown"]]
                  /\ votedUp' = [votedUp EXCEPT ![dst] = TRUE]
                  /\ UNCHANGED <<incr, interm, acks, fromRunning, tdt, decision, msgs>>
             \* Source in RUNNING and dst was IDLE: dst joins in RUNNING
             [] (sDec = "none" /\ sSt = "RUNNING" /\ state[dst] = "IDLE") ->
                  /\ state' = [state EXCEPT ![dst] = "RUNNING"]
                  /\ UNCHANGED <<parent, incr, interm, votes, acks, votedUp,
                                 fromRunning, tdt, decision, msgs>>
             \* Otherwise dst already holds at least the migrated progress
             [] OTHER ->
                  UNCHANGED <<state, parent, incr, interm, votes, acks,
                              votedUp, fromRunning, tdt, decision, msgs>>
        /\ UNCHANGED <<parts, blocked, transfersUsed, clientState,
                       retryVotes, clientResp>>

\* Algorithm 2 lines 11-18: under lock_t on src, record dst in interm[src]
\* (when src is still in RUNNING or PREPARE, cf. Algorithm 1 lines 3 & 6 vs. 9)
\* and unblock src's 2PC log commits.
FinishTransfer ==
  /\ inFlightXfer # None
  /\ inFlightXfer.phase = "Committed"
  /\ LET src == inFlightXfer.src
         dst == inFlightXfer.dst
         addSet == IF state[src] \in {"RUNNING", "PREPARE"}
                   THEN {dst} \ Children(src)
                   ELSE {}
     IN /\ interm'       = [interm EXCEPT ![src] = @ \cup addSet]
        /\ blocked'      = [blocked EXCEPT ![src] = FALSE]
        /\ inFlightXfer' = None
        /\ UNCHANGED <<state, parent, parts, incr, votes, acks, votedUp,
                       fromRunning, tdt, decision, host, transfersUsed, msgs,
                       clientState, retryVotes, clientResp>>

-----------------------------------------------------------------------------
(* TDT Expiry and Client Retry on Recreated Coordinator (Sections 5.2-5.3) *)

EvictTDT(n) ==
  /\ AllowTDTEvict
  /\ state[n] = "TOMBSTONE"
  /\ tdt[n] # "none"
  /\ tdt' = [tdt EXCEPT ![n] = "none"]
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, decision, host, inFlightXfer,
                 transfersUsed, msgs, clientState, retryVotes, clientResp>>

DeliverClientReply ==
  /\ clientState = "WAITING"
  /\ decision[Root] \in {"COMMIT", "ABORT"}
  /\ clientState' = "DONE"
  /\ clientResp'  = decision[Root]
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs, retryVotes>>

\* Figure 6 / Figure 7: Final response from Root to client is lost while Root
\* finishes clearing its TCT (`state[Root] = "TOMBSTONE"`).
LoseClientReply ==
  /\ AllowRetry
  /\ clientState = "WAITING"
  /\ state[Root] = "TOMBSTONE"
  /\ clientState' = "LOST"
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs, retryVotes, clientResp>>

\* Client resends Commit, recreating the coordinator at Root. If Root's TDT
\* still holds the terminal decision, Root answers directly; otherwise Root
\* probes its SQL-layer participants `parts[Root]`.
StartRetry ==
  /\ clientState = "LOST"
  /\ IF tdt[Root] # "none"
     THEN /\ clientState' = "DONE"
          /\ clientResp'  = tdt[Root]
          /\ UNCHANGED retryVotes
     ELSE /\ clientState' = "PROBING"
          /\ retryVotes'  = [c \in parts[Root] |-> "pending"]
          /\ UNCHANGED clientResp
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs>>

ProbeParticipant(c) ==
  /\ clientState = "PROBING"
  /\ c \in parts[Root]
  /\ retryVotes[c] = "pending"
  /\ LET reply == IF state[c] = "COMMIT" THEN "ok_tct"
                  ELSE IF tdt[c] = "COMMIT" THEN "ok_tdt"
                  ELSE IF state[c] = "ABORT" \/ tdt[c] = "ABORT" THEN "no"
                  ELSE "prep_unknown"
     IN retryVotes' = [retryVotes EXCEPT ![c] = reply]
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs, clientState, clientResp>>

ResolveRetry ==
  /\ clientState = "PROBING"
  /\ \A c \in parts[Root] : retryVotes[c] # "pending"
  /\ clientState' = "DONE"
  /\ clientResp'  =
       IF parts[Root] = {} \/ (\E c \in parts[Root] : retryVotes[c] = "prep_unknown")
       THEN "TRANS_UNKNOWN"
       ELSE IF \A c \in parts[Root] : retryVotes[c] \in {"ok_tct", "ok_tdt"}
            THEN "COMMIT"
            ELSE "ABORT"
  /\ UNCHANGED <<state, parent, parts, incr, interm, votes, acks, votedUp,
                 fromRunning, blocked, tdt, decision, host, inFlightXfer,
                 transfersUsed, msgs, retryVotes>>

-----------------------------------------------------------------------------
(* Next-State Relation and Safety Specification *)

Next ==
  \/ RootStartToCommit
  \/ \E n \in LS : Handle2pcPrepareRequest(n)
  \/ \E n \in LS : Handle2pcDuplicatePrepareRequest(n)
  \/ \E n \in LS : HandleOrphan2pcPrepareRequest(n)
  \/ \E n \in LS : Handle2pcPrepareResponse(n)
  \/ \E n \in LS : Handle2pcCommitDecided(n)
  \/ \E n \in LS : Handle2pcAbortDecided(n)
  \/ \E n \in LS : Handle2pcCommitRequest(n)
  \/ \E n \in LS : Handle2pcAbortRequest(n)
  \/ \E n \in LS : HandleOrphan2pcCommitRequest(n)
  \/ \E n \in LS : HandleOrphan2pcAbortRequest(n)
  \/ \E n \in LS : InternalAbort(n)
  \/ \E n \in LS : DropRunningCtx(n)
  \/ \E n \in LS : Handle2pcAckResponse(n)
  \/ \E n \in LS : ForgetCtx(n)
  \/ \E p \in Part, dst \in LS : BeginTransfer(p, dst)
  \/ CommitTransferLogs
  \/ FinishTransfer
  \/ \E n \in LS : EvictTDT(n)
  \/ DeliverClientReply
  \/ LoseClientReply
  \/ StartRetry
  \/ \E c \in parts[Root] : ProbeParticipant(c)
  \/ ResolveRetry

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Safety Invariants and Temporal Monotonicity Properties *)

MsgOK(m) ==
  /\ m.src \in LS
  /\ m.dst \in LS
  /\ \/ /\ m.type \in {"PrepareReq", "Commit", "Abort", "Ack"}
     \/ /\ m.type = "PrepareResp"
        /\ m.status \in {"ok", "no", "prep_unknown"}

XferOK ==
  \/ inFlightXfer = None
  \/ /\ inFlightXfer.phase \in {"Blocked", "Committed"}
     /\ inFlightXfer.part \in Part
     /\ inFlightXfer.src \in LS
     /\ inFlightXfer.dst \in LS \ {inFlightXfer.src}
     /\ inFlightXfer.snapState \in {"RUNNING", "PREPARE", "COMMIT", "ABORT"}
     /\ inFlightXfer.snapDec \in {"none", "COMMIT", "ABORT"}

OutsideCommitWindow ==
  inFlightXfer = None \/ inFlightXfer.phase = "Blocked"

TypeOK ==
  /\ state \in [LS -> States]
  /\ parent \in [LS -> LS \cup {None}]
  /\ parts \in [LS -> SUBSET LS]
  /\ incr \in [LS -> SUBSET LS]
  /\ interm \in [LS -> SUBSET LS]
  /\ \A n \in LS : state[n] = "PREPARE" =>
       /\ DOMAIN votes[n] = Children(n)
       /\ \A c \in Children(n) : votes[n][c] \in {"unknown", "ok", "no", "prep_unknown"}
  /\ \A n \in LS : state[n] \in {"COMMIT", "ABORT"} =>
       /\ DOMAIN acks[n] = Children(n)
       /\ \A c \in Children(n) : acks[n][c] \in BOOLEAN
  /\ votedUp \in [LS -> BOOLEAN]
  /\ fromRunning \in [LS -> BOOLEAN]
  /\ blocked \in [LS -> BOOLEAN]
  /\ tdt \in [LS -> {"none", "COMMIT", "ABORT"}]
  /\ decision \in [LS -> {"none", "COMMIT", "ABORT"}]
  /\ host \in [Part -> LS]
  /\ XferOK
  /\ transfersUsed \in 0..MaxTransfers
  /\ \A m \in msgs : MsgOK(m)
  /\ clientState \in {"WAITING", "LOST", "PROBING", "DONE"}
  /\ retryVotes \in [InitParts(Root) -> {"pending", "ok_tct", "ok_tdt", "no", "prep_unknown"}]
  /\ clientResp \in {"PENDING", "COMMIT", "ABORT", "TRANS_UNKNOWN"}

\* Theorem 6.1(a): No two log streams ever reach conflicting terminal outcomes.
Agreement ==
  /\ \A u, v \in LS : ~(decision[u] = "COMMIT" /\ decision[v] = "ABORT")
  /\ \A u \in LS : state[u] \in {"COMMIT", "ABORT"} => decision[u] = state[u]
  /\ \A u \in LS : tdt[u] # "none" => tdt[u] = decision[u]

\* Lemma A.4 (Running-stream guard): Once any stream commits, no active stream
\* remains in RUNNING or ABORT and no Abort message exists.
CommitRequiresAllPrepared ==
  (\E u \in LS : decision[u] = "COMMIT") =>
    /\ \A v \in LS : state[v] # "IDLE" => state[v] \in {"PREPARE", "COMMIT", "TOMBSTONE"}
    /\ ~(\E m \in msgs : m.type = "Abort")

\* Lemma A.3 (First-parent arborescence): Whenever no stream has committed,
\* every stream that entered PREPARE from RUNNING traces back to Root via
\* acyclic first-parent pointers, even when `Children` contains cycles or
\* other branches have aborted.
RECURSIVE ReachesRootViaParent(_, _)
ReachesRootViaParent(u, k) ==
  IF u = Root THEN TRUE
  ELSE IF k = 0 \/ parent[u] = None THEN FALSE
  ELSE /\ fromRunning[parent[u]]
       /\ u \in Children(parent[u])
       /\ ReachesRootViaParent(parent[u], k - 1)

FirstParentAcyclic ==
  (\A u \in LS : decision[u] # "COMMIT") =>
    (\A u \in LS : fromRunning[u] => ReachesRootViaParent(u, Cardinality(LS)))

\* Theorems 4.1 & 4.3 and Lemma A.2 (Transfer principle & active-stream coverage):
\* Every partition host is active; outside the [CommitTransferLogs, FinishTransfer)
\* window, every active stream lies in Reachable(ActiveEdges, Root) or has already
\* recorded a terminal decision; and terminal source snapshots migrate immediately
\* on CommitTransferLogs.
TransferPrinciple ==
  /\ \A p \in Part : state[host[p]] # "IDLE"
  /\ OutsideCommitWindow =>
       (\A u \in LS :
          state[u] # "IDLE" =>
            (u \in Reachable(ActiveEdges, Root) \/ decision[u] # "none"))
  /\ (inFlightXfer # None /\ inFlightXfer.phase = "Committed"
      /\ inFlightXfer.snapDec \in {"COMMIT", "ABORT"}) =>
       decision[inFlightXfer.dst] = inFlightXfer.snapDec

\* Theorem 2.2 & Theorem 6.1(b) (Minimum participant set & final-host agreement):
\* Outside the [CommitTransferLogs, FinishTransfer) window, every partition's host
\* either lies in the Root-rooted participant graph or has already migrated a
\* terminal decision; decided hosts always match Root; and once all contexts
\* settle to TOMBSTONE every final host holds Root's terminal decision.
MinParticipantSet ==
  /\ OutsideCommitWindow =>
       (\A p \in Part :
          \/ host[p] \in Reachable(ActiveEdges, Root)
          \/ decision[host[p]] # "none")
  /\ \A p \in Part :
       (decision[Root] # "none" /\ decision[host[p]] # "none") =>
         decision[host[p]] = decision[Root]
  /\ (inFlightXfer = None /\ \A u \in LS : state[u] \in {"IDLE", "TOMBSTONE"}) =>
       (\A p \in Part : decision[host[p]] = decision[Root])

\* Section 5.2-5.3 (Unknown-state non-fabrication): Client responses never
\* fabricate COMMIT for an aborted transaction or ABORT without an aborted root,
\* and TRANS_UNKNOWN arises only on a recreated coordinator after TDT eviction.
ClientReplyConsistent ==
  /\ clientResp = "COMMIT" => decision[Root] = "COMMIT"
  /\ clientResp = "ABORT"  => decision[Root] = "ABORT"
  /\ clientResp = "TRANS_UNKNOWN" =>
       /\ AllowRetry
       /\ state[Root] = "TOMBSTONE"
       /\ tdt[Root] = "none"
       /\ \E u \in LS : state[u] = "TOMBSTONE" /\ tdt[u] = "none"

\* Section 5.3: While TDT retains terminal decisions on all decided streams,
\* client retries never surface TRANS_UNKNOWN.
NoUnknownWhenTDTRetained ==
  (\A u \in LS : decision[u] # "none" => tdt[u] = decision[u]) =>
    clientResp # "TRANS_UNKNOWN"

\* Temporal monotonicity properties (Theorem 6.1 stability)
DecisionStable ==
  [][\A u \in LS : decision[u] # "none" => decision'[u] = decision[u]]_vars

StateMonotonic ==
  [][\A u \in LS : StateRank(state[u]) <= StateRank(state'[u])]_vars

-----------------------------------------------------------------------------
(* Liveness Specification and Properties (Section 4.6, Theorem 6.2) *)

\* Progress assumptions: weak fairness on all protocol, in-flight transfer
\* completion, and client-delivery/retry-resolution steps; transfers, internal
\* aborts, context loss, reply loss, and TDT eviction remain optional.
Fairness ==
  /\ WF_vars(RootStartToCommit)
  /\ \A n \in LS : WF_vars(Handle2pcPrepareRequest(n))
  /\ \A n \in LS : WF_vars(Handle2pcDuplicatePrepareRequest(n))
  /\ \A n \in LS : WF_vars(HandleOrphan2pcPrepareRequest(n))
  /\ \A n \in LS : WF_vars(Handle2pcPrepareResponse(n))
  /\ \A n \in LS : WF_vars(Handle2pcCommitDecided(n))
  /\ \A n \in LS : WF_vars(Handle2pcAbortDecided(n))
  /\ \A n \in LS : WF_vars(Handle2pcCommitRequest(n))
  /\ \A n \in LS : WF_vars(Handle2pcAbortRequest(n))
  /\ \A n \in LS : WF_vars(HandleOrphan2pcCommitRequest(n))
  /\ \A n \in LS : WF_vars(HandleOrphan2pcAbortRequest(n))
  /\ \A n \in LS : WF_vars(Handle2pcAckResponse(n))
  /\ \A n \in LS : WF_vars(ForgetCtx(n))
  /\ WF_vars(CommitTransferLogs)
  /\ WF_vars(FinishTransfer)
  /\ WF_vars(DeliverClientReply)
  /\ WF_vars(StartRetry)
  /\ \A c \in InitParts(Root) : WF_vars(ProbeParticipant(c))
  /\ WF_vars(ResolveRetry)

LiveSpec == Init /\ [][Next]_vars /\ Fairness

\* Theorem 6.2: Eventually Root and every active log stream (including every
\* final partition host) reach a common terminal COMMIT or ABORT outcome.
EventuallyAllDecide ==
  <>[](\E d \in {"COMMIT", "ABORT"} :
         /\ decision[Root] = d
         /\ \A u \in LS : state[u] # "IDLE" => decision[u] = d
         /\ \A p \in Part : decision[host[p]] = d)

\* Every active log stream eventually finishes acknowledgement collection and
\* reclaims its TCT (`TOMBSTONE`), even across circular transfer graphs.
EventuallyAllTombstone ==
  <>[](\A u \in LS : state[u] \in {"IDLE", "TOMBSTONE"})

\* Client boundary eventually receives a sound terminal or conservative outcome.
ClientEventuallyResolved ==
  <>[](clientResp \in {"COMMIT", "ABORT", "TRANS_UNKNOWN"})

-----------------------------------------------------------------------------
(* Reachability Witnesses: each must be VIOLATED (`REACHED`) to confirm     *)
(* that the corresponding protocol path is non-vacuously exercisable.       *)

NoCommitTombstone ==
  ~(decision[Root] = "COMMIT" /\ \A u \in LS : state[u] \in {"IDLE", "TOMBSTONE"})

NoInternalAbortPropagation ==
  ~(\E u \in DOMAIN votes[Root] :
      /\ fromRunning[Root]
      /\ votes[Root][u] = "no"
      /\ tdt[u] = "ABORT"
      /\ decision[Root] = "ABORT"
      /\ state[Root] = "TOMBSTONE")

NoTransferInRunning ==
  ~(\E u \in IdleLS :
      /\ fromRunning[u]
      /\ decision[u] = "COMMIT"
      /\ decision[Root] = "COMMIT")

NoTransferInPrepare ==
  ~(\E u \in IdleLS :
      /\ ~fromRunning[u]
      /\ state[u] = "PREPARE"
      /\ parent[u] # None)

NoTransferInCommit ==
  ~(\E p \in Part, u \in IdleLS :
      /\ host[p] = u
      /\ ~fromRunning[u]
      /\ parent[u] # None
      /\ decision[u] = "COMMIT"
      /\ \A w \in LS : u \notin Children(w))

NoCircularPrepare ==
  ~(\E u, v \in LS \ {Root} :
      /\ u # v
      /\ fromRunning[u] /\ fromRunning[v]
      /\ v \in Children(u) /\ u \in Children(v)
      /\ parent[u] # v
      /\ MsgPrepareReq(v, u) \in msgs
      /\ MsgPrepareReq(u, v) \in msgs
      /\ MsgPrepareResp(u, v, "ok") \in msgs
      /\ decision[Root] = "COMMIT"
      /\ state[Root] = "TOMBSTONE")

NoTDTRetryCommit ==
  ~(AllowRetry /\ clientState = "DONE" /\ clientResp = "COMMIT"
    /\ state[Root] = "TOMBSTONE" /\ tdt[Root] = "none"
    /\ \E c \in parts[Root] : retryVotes[c] = "ok_tdt")

NoTransUnknownOnRecreatedRetry ==
  ~(clientResp = "TRANS_UNKNOWN" /\ decision[Root] = "COMMIT")

NoAbortOnNewCoordUnknown ==
  ~(\E u \in Children(Root) :
      /\ votes[Root][u] = "prep_unknown"
      /\ decision[Root] = "ABORT"
      /\ clientResp = "ABORT")

\* Liveness witness (checked under LiveSpec): circular transfer graph exercises
\* duplicate-prepare handling, commits, and reclaims all contexts cleanly.
NoLiveCircularCommit ==
  ~(\E u, v \in LS \ {Root} :
      /\ u # v
      /\ fromRunning[u] /\ fromRunning[v]
      /\ v \in Children(u) /\ u \in Children(v)
      /\ parent[u] # v
      /\ MsgPrepareReq(v, u) \in msgs
      /\ MsgPrepareReq(u, v) \in msgs
      /\ MsgPrepareResp(u, v, "ok") \in msgs
      /\ decision[Root] = "COMMIT"
      /\ \A w \in LS : state[w] \in {"IDLE", "TOMBSTONE"})

=============================================================================
