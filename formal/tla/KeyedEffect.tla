----------------------------- MODULE KeyedEffect -----------------------------
EXTENDS Naturals
CONSTANT MaxCrashes
ASSUME MaxCrashes \in Nat
VARIABLES phase, intent, intentStable, receipt, receiptStable, launches, crashes
vars == <<phase, intent, intentStable, receipt, receiptStable, launches, crashes>>
Init == /\ phase = "idle" /\ intent = "absent" /\ intentStable = FALSE
        /\ receipt = "absent" /\ receiptStable = FALSE /\ launches = 0 /\ crashes = 0
Reserve == /\ phase = "idle" /\ intent = "absent"
           /\ phase' = "preparing" /\ intent' = "partial"
           /\ UNCHANGED <<intentStable, receipt, receiptStable, launches, crashes>>
WriteIntent == /\ phase = "preparing" /\ intent = "partial" /\ intent' = "complete"
               /\ UNCHANGED <<phase, intentStable, receipt, receiptStable, launches, crashes>>
SyncIntent == /\ phase = "preparing" /\ intent = "complete" /\ ~intentStable
              /\ intentStable' = TRUE
              /\ UNCHANGED <<phase, intent, receipt, receiptStable, launches, crashes>>
Dispatch == /\ phase = "preparing" /\ intent = "complete" /\ intentStable
            /\ phase' = "dispatched" /\ launches' = launches + 1
            /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, crashes>>
Observe == /\ phase = "dispatched" /\ phase' = "observed"
           /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, launches, crashes>>
ReserveReceipt == /\ phase = "observed" /\ phase' = "recording" /\ receipt' = "partial"
                  /\ UNCHANGED <<intent, intentStable, receiptStable, launches, crashes>>
WriteReceipt == /\ phase = "recording" /\ receipt = "partial" /\ receipt' = "complete"
                /\ UNCHANGED <<phase, intent, intentStable, receiptStable, launches, crashes>>
SyncReceipt == /\ phase = "recording" /\ receipt = "complete" /\ ~receiptStable
               /\ receiptStable' = TRUE
               /\ UNCHANGED <<phase, intent, intentStable, receipt, launches, crashes>>
Acknowledge == /\ phase = "recording" /\ receiptStable /\ phase' = "done"
               /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, launches, crashes>>
Survivors(value, stable) == IF stable THEN {"complete"}
                           ELSE IF value = "absent" THEN {"absent"}
                           ELSE IF value = "partial" THEN {"absent", "partial"}
                           ELSE {"absent", "partial", "complete"}
Crash(keptIntent, keptReceipt) ==
    /\ phase \notin {"interrupted", "replayed", "uncertain", "rejected"}
    /\ crashes < MaxCrashes
    /\ keptIntent \in Survivors(intent, intentStable)
    /\ keptReceipt \in Survivors(receipt, receiptStable)
    /\ phase' = "interrupted" /\ crashes' = crashes + 1
    /\ intent' = keptIntent /\ receipt' = keptReceipt
    /\ UNCHANGED <<intentStable, receiptStable, launches>>
Recover == /\ phase = "interrupted"
           /\ phase' = IF intent = "absent" THEN "idle"
                       ELSE IF intent # "complete" THEN "rejected"
                       ELSE IF receipt = "complete" THEN "replayed"
                       ELSE IF receipt = "partial" THEN "rejected"
                       ELSE "uncertain"
           /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, launches, crashes>>
Done == /\ phase \in {"done", "replayed", "uncertain", "rejected"} /\ UNCHANGED vars
Next == Reserve \/ WriteIntent \/ SyncIntent \/ Dispatch \/ Observe \/ ReserveReceipt
        \/ WriteReceipt \/ SyncReceipt \/ Acknowledge \/ Recover \/ Done
        \/ (\E ki \in {"absent", "partial", "complete"}, kr \in {"absent", "partial", "complete"} : Crash(ki, kr))
Spec == Init /\ [][Next]_vars
FairSpec == /\ Spec /\ WF_vars(Recover)
            /\ WF_vars(Reserve) /\ WF_vars(WriteIntent) /\ WF_vars(SyncIntent)
            /\ WF_vars(Dispatch) /\ WF_vars(Observe) /\ WF_vars(ReserveReceipt)
            /\ WF_vars(WriteReceipt) /\ WF_vars(SyncReceipt) /\ WF_vars(Acknowledge)
TypeOK == /\ phase \in {"idle", "preparing", "dispatched", "observed", "recording", "done",
                        "interrupted", "replayed", "uncertain", "rejected"}
          /\ intent \in {"absent", "partial", "complete"}
          /\ receipt \in {"absent", "partial", "complete"}
          /\ intentStable \in BOOLEAN /\ receiptStable \in BOOLEAN
          /\ launches \in Nat /\ crashes \in 0..MaxCrashes
DurableBeforeDispatch == launches > 0 => intentStable
NoBlindReplay == launches <= 1
KnownReceiptOnly == phase \in {"done", "replayed"} => receipt = "complete"
ReceiptRequiresExecution == receipt # "absent" => launches > 0
EventuallyResolved == <> (phase \in {"done", "replayed", "uncertain", "rejected"})
=============================================================================
