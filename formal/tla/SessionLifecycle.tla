------------------------- MODULE SessionLifecycle -------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Requests, NotificationBlocksCancel
ASSUME /\ Requests # {} /\ IsFiniteSet(Requests)
       /\ NotificationBlocksCancel \in BOOLEAN
VARIABLES life, health, status, cancelled, jobs, history, sink, reported,
          actorJoined, notificationsJoined, borrowed
vars == <<life, health, status, cancelled, jobs, history, sink, reported,
          actorJoined, notificationsJoined, borrowed>>
Outcomes == {"completed", "cancelled", "failed"}
Live == {r \in Requests : status[r] = "running"}
Pending == {r \in Requests : status[r] \in {"queued", "running"}}
Init == /\ life = "open" /\ health = "healthy"
        /\ status = [r \in Requests |-> "unused"]
        /\ cancelled = {} /\ jobs = {} /\ history = {}
        /\ sink = "healthy" /\ reported = [r \in Requests |-> "pending"]
        /\ actorJoined = FALSE /\ notificationsJoined = FALSE /\ borrowed = TRUE
Admit(r) == /\ life = "open" /\ health = "healthy" /\ sink = "healthy"
            /\ status[r] = "unused"
            /\ status' = [status EXCEPT ![r] = "queued"]
            /\ UNCHANGED <<life, health, cancelled, jobs, history, sink, reported,
                            actorJoined, notificationsJoined, borrowed>>
Start(r) == /\ life \in {"open", "closing"} /\ health = "healthy"
            /\ Live = {} /\ status[r] = "queued" /\ r \notin cancelled
            /\ status' = [status EXCEPT ![r] = "running"]
            /\ UNCHANGED <<life, health, cancelled, jobs, history, sink, reported,
                            actorJoined, notificationsJoined, borrowed>>
StartJob(r) == /\ life \in {"open", "closing"} /\ health = "healthy"
               /\ status[r] = "running" /\ r \notin cancelled /\ r \notin jobs
               /\ jobs' = jobs \cup {r}
               /\ UNCHANGED <<life, health, status, cancelled, history, sink, reported,
                               actorJoined, notificationsJoined, borrowed>>
JoinJob(r) == /\ r \in jobs /\ jobs' = jobs \ {r}
              /\ UNCHANGED <<life, health, status, cancelled, history, sink, reported,
                              actorJoined, notificationsJoined, borrowed>>
Finish(r, outcome) == /\ status[r] = "running" /\ r \notin jobs
                      /\ outcome \in {"completed", "failed"}
                      /\ status' = [status EXCEPT ![r] = outcome]
                      /\ history' = history \cup {<<r, outcome>>}
                      /\ UNCHANGED <<life, health, cancelled, jobs, sink, reported,
                                      actorJoined, notificationsJoined, borrowed>>
Cancel(r) == /\ life = "open" /\ health = "healthy" /\ r \in Pending
             /\ r \notin cancelled
             /\ (~NotificationBlocksCancel \/ sink = "healthy")
             /\ cancelled' = cancelled \cup {r}
             /\ UNCHANGED <<life, health, status, jobs, history, sink, reported,
                             actorJoined, notificationsJoined, borrowed>>
SettleCancel(r) == /\ r \in cancelled /\ r \in Pending
                   /\ status' = [status EXCEPT ![r] = "cancelled"]
                   /\ history' = history \cup {<<r, "cancelled">>}
                   /\ UNCHANGED <<life, health, cancelled, jobs, sink, reported,
                                   actorJoined, notificationsJoined, borrowed>>
RetireForReplacement(r) ==
    /\ life = "open" /\ health = "healthy" /\ sink = "healthy" /\ r \in Pending
    /\ status' = [status EXCEPT ![r] = "cancelled"]
    /\ history' = history \cup {<<r, "cancelled">>}
    /\ cancelled' = cancelled \cup {r}
    /\ UNCHANGED <<life, health, jobs, sink, reported, actorJoined, notificationsJoined, borrowed>>
NeedRecovery == /\ life = "open" /\ health = "healthy" /\ Pending = {}
                /\ \E r \in cancelled : status[r] = "cancelled"
                /\ health' = "recovering"
                /\ UNCHANGED <<life, status, cancelled, jobs, history, sink, reported,
                                actorJoined, notificationsJoined, borrowed>>
FailSink == /\ ~notificationsJoined /\ sink = "healthy" /\ \E r \in Requests : status[r] # "unused"
            /\ sink' = "failed"
            /\ UNCHANGED <<life, health, status, cancelled, jobs, history, reported,
                            actorJoined, notificationsJoined, borrowed>>
Report(r) == /\ status[r] \in Outcomes /\ reported[r] = "pending"
             /\ reported' = [reported EXCEPT ![r] = status[r]]
             /\ UNCHANGED <<life, health, status, cancelled, jobs, history, sink,
                             actorJoined, notificationsJoined, borrowed>>
Recover(ok) == /\ life = "open" /\ health = "recovering" /\ jobs = {}
               /\ health' = IF ok THEN "healthy" ELSE "faulted"
               /\ UNCHANGED <<life, status, cancelled, jobs, history, sink, reported,
                               actorJoined, notificationsJoined, borrowed>>
Fault == /\ life = "open" /\ health \in {"healthy", "recovering"}
         /\ health' = "faulted"
         /\ status' = [r \in Requests |-> IF r \in Pending THEN "failed" ELSE status[r]]
         /\ history' = history \cup {<<r, "failed">> : r \in Pending}
         /\ cancelled' = cancelled \cup Pending
         /\ UNCHANGED <<life, jobs, sink, reported, actorJoined, notificationsJoined, borrowed>>
Close == /\ life = "open" /\ life' = "closing"
         /\ UNCHANGED <<health, status, cancelled, jobs, history, sink, reported,
                         actorJoined, notificationsJoined, borrowed>>
StopWorker == /\ life = "closing" /\ life' = "draining"
              /\ cancelled' = cancelled \cup Pending
              /\ UNCHANGED <<health, status, jobs, history, sink, reported,
                              actorJoined, notificationsJoined, borrowed>>
JoinActor == /\ life = "draining" /\ jobs = {} /\ Pending = {} /\ ~actorJoined
             /\ actorJoined' = TRUE
             /\ UNCHANGED <<life, health, status, cancelled, jobs, history, sink,
                             reported, notificationsJoined, borrowed>>
JoinNotifications == /\ life = "draining" /\ actorJoined /\ ~notificationsJoined
                     /\ notificationsJoined' = TRUE
                     /\ UNCHANGED <<life, health, status, cancelled, jobs, history,
                                     sink, reported, actorJoined, borrowed>>
Release == /\ life = "draining" /\ actorJoined /\ notificationsJoined
           /\ life' = "closed" /\ health' = "stopped" /\ borrowed' = FALSE
           /\ UNCHANGED <<status, cancelled, jobs, history, sink, reported,
                           actorJoined, notificationsJoined>>
Done == /\ life = "closed" /\ UNCHANGED vars
Next == (\E r \in Requests : Admit(r) \/ Start(r) \/ StartJob(r) \/ JoinJob(r) \/ Cancel(r)
                            \/ SettleCancel(r) \/ RetireForReplacement(r) \/ Report(r)
                            \/ (\E outcome \in {"completed", "failed"} : Finish(r, outcome)))
        \/ FailSink \/ NeedRecovery \/ (\E ok \in BOOLEAN : Recover(ok)) \/ Fault \/ Close
        \/ StopWorker \/ JoinActor \/ JoinNotifications \/ Release \/ Done
Spec == Init /\ [][Next]_vars
FairSpec == /\ Spec
            /\ \A r \in Requests : WF_vars(JoinJob(r)) /\ WF_vars(SettleCancel(r))
            /\ WF_vars(StopWorker) /\ WF_vars(JoinActor) /\ WF_vars(JoinNotifications) /\ WF_vars(Release)
            /\ WF_vars(Recover(TRUE) \/ Recover(FALSE))
TypeOK == /\ life \in {"open", "closing", "draining", "closed"}
          /\ health \in {"healthy", "recovering", "faulted", "stopped"}
          /\ status \in [Requests -> ({"unused", "queued", "running"} \cup Outcomes)]
          /\ cancelled \subseteq Requests /\ jobs \subseteq Requests
          /\ history \subseteq (Requests \X Outcomes)
          /\ sink \in {"healthy", "failed"}
          /\ reported \in [Requests -> ({"pending"} \cup Outcomes)]
          /\ actorJoined \in BOOLEAN /\ notificationsJoined \in BOOLEAN /\ borrowed \in BOOLEAN
OneActive == Cardinality(Live) <= 1
TerminalImmutable == \A r \in Requests :
    /\ Cardinality({o \in Outcomes : <<r, o>> \in history}) <= 1
    /\ (status[r] \in Outcomes => <<r, status[r]>> \in history)
    /\ \A o \in Outcomes : <<r, o>> \in history => status[r] = o
ReportingPreservesCompletion == \A r \in Requests :
    reported[r] # "pending" => reported[r] = status[r]
CancelAvailable == \A r \in Requests :
    life = "open" /\ health = "healthy" /\ r \in Pending /\ r \notin cancelled
    => ENABLED Cancel(r)
JoinedRelease == /\ (~borrowed => jobs = {} /\ Pending = {} /\ actorJoined /\ notificationsJoined)
                 /\ (life = "closed" <=> ~borrowed)
                 /\ (health = "stopped" <=> life = "closed")
NoExecutionWhenUnhealthy == health # "healthy" =>
    ~\E r \in Requests : ENABLED Admit(r) \/ ENABLED Start(r) \/ ENABLED StartJob(r)
ClosedAdmission == life # "open" => ~\E r \in Requests : ENABLED Admit(r)
ClosingTerminates == life \in {"closing", "draining"} ~> life = "closed"
CancellationSettles == \A r \in Requests : r \in cancelled ~> status[r] \in Outcomes
RecoveryTerminates == health = "recovering" ~> health # "recovering"
=============================================================================
