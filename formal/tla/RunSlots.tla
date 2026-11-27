------------------------------ MODULE RunSlots ------------------------------
EXTENDS Naturals, FiniteSets
CONSTANT MaxSuspensions
ASSUME MaxSuspensions \in Nat
VARIABLES active, suspended, phase, serial, token, receipts, resumes
vars == <<active, suspended, phase, serial, token, receipts, resumes>>
Runs == {1, 2}
Init == /\ active = 0 /\ suspended = 0
        /\ phase = [r \in Runs |-> "unused"]
        /\ serial = 0 /\ token = 0 /\ receipts = {} /\ resumes = {}
Install(r) == /\ active = 0 /\ phase[r] = "unused"
              /\ active' = r /\ phase' = [phase EXCEPT ![r] = "active"]
              /\ UNCHANGED <<suspended, serial, token, receipts, resumes>>
Suspend == /\ active = 1 /\ suspended = 0 /\ serial < MaxSuspensions
           /\ active' = 0 /\ suspended' = 1
           /\ phase' = [phase EXCEPT ![1] = "suspended"]
           /\ serial' = serial + 1 /\ token' = serial + 1
           /\ receipts' = receipts \cup {serial + 1}
           /\ UNCHANGED resumes
Resume(tag) == /\ active = 0 /\ suspended = 1 /\ tag = token
               /\ tag \in receipts
               /\ active' = 1 /\ suspended' = 0
               /\ phase' = [phase EXCEPT ![1] = "active"]
               /\ resumes' = resumes \cup {<<tag, token>>} /\ token' = 0
               /\ UNCHANGED <<serial, receipts>>
Clear(r) == /\ phase[r] \in {"active", "suspended"}
            /\ active' = IF active = r THEN 0 ELSE active
            /\ suspended' = IF suspended = r THEN 0 ELSE suspended
            /\ token' = IF suspended = r THEN 0 ELSE token
            /\ phase' = [phase EXCEPT ![r] = "done"]
            /\ UNCHANGED <<serial, receipts, resumes>>
Quiescent == /\ active = 0 /\ suspended = 0
             /\ \A r \in Runs : phase[r] = "done"
Done == /\ Quiescent /\ UNCHANGED vars
Next == (\E r \in Runs : Install(r) \/ Clear(r)) \/ Suspend
        \/ (\E tag \in 1..MaxSuspensions : Resume(tag)) \/ Done
Spec == Init /\ [][Next]_vars
TypeOK == /\ active \in 0..2 /\ suspended \in {0, 1}
          /\ phase \in [Runs -> {"unused", "active", "suspended", "done"}]
          /\ serial \in 0..MaxSuspensions /\ token \in 0..MaxSuspensions
          /\ receipts \subseteq 1..MaxSuspensions
          /\ resumes \subseteq ((1..MaxSuspensions) \X (1..MaxSuspensions))
ExclusiveSlots == active = 0 \/ active # suspended
NoLostRun == \A r \in Runs :
    /\ (phase[r] = "active" <=> active = r)
    /\ (phase[r] = "suspended" <=> suspended = r)
NoStaleResume == \A pair \in resumes : pair[1] = pair[2]
TokenOwned == (suspended = 0 <=> token = 0)
=============================================================================
