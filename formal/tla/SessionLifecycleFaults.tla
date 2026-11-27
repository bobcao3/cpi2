----------------------- MODULE SessionLifecycleFaults -----------------------
EXTENDS SessionLifecycle

RelabelFinish(r, outcome) ==
    /\ status[r] \in ({"running"} \cup Outcomes) /\ r \notin jobs
    /\ outcome \in {"completed", "failed"}
    /\ status' = [status EXCEPT ![r] = outcome]
    /\ history' = history \cup {<<r, outcome>>}
    /\ UNCHANGED <<life, health, cancelled, jobs, sink, reported,
                    actorJoined, notificationsJoined, borrowed>>

RelabelReport(r) ==
    /\ status[r] \in Outcomes /\ reported[r] = "pending"
    /\ reported' = [reported EXCEPT ![r] = IF sink = "failed" THEN "failed" ELSE status[r]]
    /\ UNCHANGED <<life, health, status, cancelled, jobs, history, sink,
                    actorJoined, notificationsJoined, borrowed>>

EarlyRelease ==
    /\ life = "draining"
    /\ life' = "closed" /\ health' = "stopped" /\ borrowed' = FALSE
    /\ UNCHANGED <<status, cancelled, jobs, history, sink, reported,
                    actorJoined, notificationsJoined>>

FaultedAdmit(r) ==
    /\ life = "open" /\ sink = "healthy" /\ status[r] = "unused"
    /\ status' = [status EXCEPT ![r] = "queued"]
    /\ UNCHANGED <<life, health, cancelled, jobs, history, sink, reported,
                    actorJoined, notificationsJoined, borrowed>>

ClosedAdmit(r) ==
    /\ health = "healthy" /\ sink = "healthy" /\ status[r] = "unused"
    /\ status' = [status EXCEPT ![r] = "queued"]
    /\ UNCHANGED <<life, health, cancelled, jobs, history, sink, reported,
                    actorJoined, notificationsJoined, borrowed>>

ConcurrentStart(r) ==
    /\ life \in {"open", "closing"} /\ health = "healthy"
    /\ status[r] = "queued" /\ r \notin cancelled
    /\ status' = [status EXCEPT ![r] = "running"]
    /\ UNCHANGED <<life, health, cancelled, jobs, history, sink, reported,
                    actorJoined, notificationsJoined, borrowed>>

UnjoinedHostSpec ==
    /\ Spec
    /\ \A r \in Requests : WF_vars(SettleCancel(r))
    /\ WF_vars(StopWorker) /\ WF_vars(JoinActor)
    /\ WF_vars(JoinNotifications) /\ WF_vars(Release)
    /\ WF_vars(Recover(TRUE) \/ Recover(FALSE))
=============================================================================
