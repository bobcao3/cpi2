--------------------------- MODULE StartupFaults ---------------------------
EXTENDS StartupFinite

UnsyncedPublish == /\ phase = "sync" /\ ~blocked /\ runtime = "waiting"
           /\ phase' = ("ready")
              /\ published' = (published \cup {g})
              /\ runtime' = "active"
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>

ProvisionalDispatch == /\ phase = "stage" /\ ~blocked
            /\ effects' = (effects \cup {g})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>

StaleJoinVM(tag) == /\ vm = "done" /\ tag \in receipts
          /\ vm' = ("joined")
              /\ vo' = ("startup")
              /\ joined' = (IF jr = "joined" THEN joined \cup {g} ELSE joined)
              /\ installs' = (installs \cup {<<g, tag>>})
              /\ UNCHANGED <<journalReceipts, g, phase, jr, vg, jg, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, released, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>

StaleJoinJournal(tag) == /\ jr = "done" /\ tag \in journalReceipts
               /\ jr' = ("joined")
              /\ jo' = ("startup")
              /\ joined' = (IF vm = "joined" THEN joined \cup {g} ELSE joined)
              /\ installs' = (installs \cup {<<g, tag>>})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, vg, jg, vo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, released, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>

UnjoinedRelease == /\ runtime \in {"none", "joined"}
           /\ phase = "closing"
           /\ phase' = ("dead")
              /\ borrowed' = (FALSE)
              /\ vo' = ("none")
              /\ jo' = ("none")
              /\ released' = (released \cup {g})
              /\ runtime' = "none"
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>

LiveRuntimeRelease == /\ TRUE
           /\ phase = "closing" /\ vm = "joined" /\ jr = "joined"
           /\ phase' = ("dead")
              /\ borrowed' = (FALSE)
              /\ vo' = ("none")
              /\ jo' = ("none")
              /\ released' = (released \cup {g})
              /\ runtime' = "none"
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>

TornRetainedCrash == /\ d.crashes < MaxCrashes
               /\ \E keep \in SUBSET s.complete, torn \in BOOLEAN :
                    /\ Crash(keep)
                    /\ (torn => s.phase \in {"write", "sync"} /\ s.g \notin s.stable)
                    /\ d' = [d EXCEPT !.crashes = @ + 1, !.torn = d.torn \/ torn,
                         !.tornMembers = IF torn THEN @ \cup {s.g} ELSE @,
                         !.retained = keep, !.checked = {}, !.evaluated = {}]

=============================================================================
