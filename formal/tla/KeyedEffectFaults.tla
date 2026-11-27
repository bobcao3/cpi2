-------------------------- MODULE KeyedEffectFaults --------------------------
EXTENDS KeyedEffect

UnsyncedDispatch ==
    /\ phase = "preparing" /\ intent = "complete"
    /\ phase' = "dispatched" /\ launches' = launches + 1
    /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, crashes>>

PartialReceiptRecover ==
    /\ phase = "interrupted"
    /\ phase' = IF intent = "absent" THEN "idle"
                ELSE IF intent # "complete" THEN "rejected"
                ELSE IF receipt \in {"complete", "partial"} THEN "replayed"
                ELSE "uncertain"
    /\ UNCHANGED <<intent, intentStable, receipt, receiptStable, launches, crashes>>

UnexecutedReceipt ==
    /\ phase = "idle" /\ phase' = "recording" /\ receipt' = "partial"
    /\ UNCHANGED <<intent, intentStable, receiptStable, launches, crashes>>

BlindRecover ==
    /\ phase = "interrupted"
    /\ phase' = IF intent = "absent" THEN "idle"
                ELSE IF intent # "complete" THEN "rejected"
                ELSE IF receipt = "complete" THEN "replayed"
                ELSE IF receipt = "partial" THEN "rejected"
                ELSE "idle"
    /\ intent' = IF phase' = "idle" THEN "absent" ELSE intent
    /\ intentStable' = IF phase' = "idle" THEN FALSE ELSE intentStable
    /\ UNCHANGED <<receipt, receiptStable, launches, crashes>>
=============================================================================
