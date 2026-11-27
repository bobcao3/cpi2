--------------------------- MODULE RunSlotsFaults ---------------------------
EXTENDS RunSlots

StaleResume(tag) ==
    /\ active = 0 /\ suspended = 1 /\ tag \in receipts
    /\ active' = 1 /\ suspended' = 0
    /\ phase' = [phase EXCEPT ![1] = "active"]
    /\ resumes' = resumes \cup {<<tag, token>>} /\ token' = 0
    /\ UNCHANGED <<serial, receipts>>

OccupiedResume(tag) ==
    /\ suspended = 1 /\ tag = token /\ tag \in receipts
    /\ active' = 1 /\ suspended' = 0
    /\ phase' = [phase EXCEPT ![1] = "active"]
    /\ resumes' = resumes \cup {<<tag, token>>} /\ token' = 0
    /\ UNCHANGED <<serial, receipts>>

AliasedSuspend ==
    /\ active = 1 /\ suspended = 0 /\ serial < MaxSuspensions
    /\ active' = active /\ suspended' = 1
    /\ phase' = [phase EXCEPT ![1] = "suspended"]
    /\ serial' = serial + 1 /\ token' = serial + 1
    /\ receipts' = receipts \cup {serial + 1}
    /\ UNCHANGED resumes

OrphanedClear(r) ==
    /\ phase[r] \in {"active", "suspended"}
    /\ active' = IF active = r THEN 0 ELSE active
    /\ suspended' = IF suspended = r THEN 0 ELSE suspended
    /\ phase' = [phase EXCEPT ![r] = "done"]
    /\ UNCHANGED <<serial, token, receipts, resumes>>
=============================================================================
