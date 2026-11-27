-------------------------- MODULE StartupFinite --------------------------
EXTENDS Startup
CONSTANT MaxGeneration, Tools, MaxCrashes
VARIABLE d
allvars == <<vars, d>>
LimitedStart(generation) == generation < MaxGeneration
DetailInit == /\ Init
              /\ \E mode \in {"fixed", "preserve"}, base \in SUBSET Tools :
                   d = [mode |-> mode, base |-> base, registry |-> base,
                        checked |-> {}, evaluated |-> {}, reason |-> "none",
                        torn |-> FALSE, tornMembers |-> {}, retained |-> {}, crashes |-> 0]
DetailStart == /\ Start /\ ~d.torn
               /\ d' = [d EXCEPT !.base = d.registry, !.checked = d.registry,
                    !.evaluated = {}, !.reason = "none"]
CheckTool(t) == /\ s.phase = "stage" /\ ~s.blocked /\ d.mode = "fixed"
                /\ t \in Tools \ d.checked
                /\ UNCHANGED vars
                /\ d' = [d EXCEPT !.checked = @ \cup {t}, !.evaluated = @ \cup {t}]
DetailValidate == /\ Validate /\ (d.mode = "preserve" \/ d.checked = Tools)
                  /\ d' = [d EXCEPT !.registry = IF d.mode = "fixed" THEN Tools ELSE @]
RejectCatalog(t) == /\ s.phase = "stage" /\ ~s.valid /\ t \in Tools
                    /\ Fail /\ d' = [d EXCEPT !.reason = "catalog"]
RejectInit == /\ s.phase = "stage" /\ s.valid /\ ~s.initialized
              /\ Fail /\ d' = [d EXCEPT !.reason = "initialize"]
WriteFailure == /\ s.phase = "write" /\ Fail
                /\ \E torn \in BOOLEAN : d' = [d EXCEPT !.reason = "write", !.torn = torn, !.retained = s.complete,
                    !.tornMembers = IF torn THEN @ \cup {s.g} ELSE @]
SyncFailure == /\ s.phase = "sync" /\ ~s.synced /\ Fail
               /\ d' = [d EXCEPT !.reason = "sync"]
DetailCrash == /\ d.crashes < MaxCrashes
               /\ \E keep \in SUBSET s.complete, torn \in BOOLEAN :
                    /\ Crash(keep)
                    /\ (torn => s.phase \in {"write", "sync"} /\ s.g \notin s.stable /\ s.g \notin keep)
                    /\ d' = [d EXCEPT !.crashes = @ + 1, !.torn = d.torn \/ torn,
                         !.tornMembers = IF torn THEN @ \cup {s.g} ELSE @,
                         !.retained = keep, !.checked = {}, !.evaluated = {}]
DetailReopen == /\ s.phase = "dead" /\ (d.torn \/ s.complete # s.stable)
                /\ IsPrefix(s.stable, s.complete)
                /\ (d.torn => s.complete = d.retained /\ s.g \notin s.complete)
                /\ UNCHANGED vars
                /\ d' = [d EXCEPT !.torn = FALSE]
TailSafety == /\ d.tornMembers \cap s.complete = {}
              /\ d.tornMembers \cap s.stable = {}
              /\ (d.torn => s.g \in d.tornMembers /\ s.g \notin s.complete
                    /\ s.complete = d.retained /\ IsPrefix(s.stable, d.retained))
Plain == Activate \/ JoinRuntime \/ (\E ok \in BOOLEAN : FinishVM(ok) \/ FinishJournal(ok))
         \/ (\E tag \in s.receipts : JoinVM(tag)) \/ (\E tag \in s.journalReceipts : JoinJournal(tag)) \/ Joined
         \/ Initialize \/ PrepareWrite \/ Write \/ Sync \/ Publish
         \/ Intent \/ Dispatch \/ Fail \/ Close \/ Release \/ Abort
DetailNext == DetailStart \/ (\E t \in Tools : CheckTool(t) \/ RejectCatalog(t))
              \/ DetailValidate \/ RejectInit \/ WriteFailure \/ SyncFailure
              \/ DetailCrash \/ DetailReopen \/ (Plain /\ UNCHANGED d)
DetailSpec == DetailInit /\ [][DetailNext]_allvars
CatalogSafety == /\ d.checked \subseteq Tools /\ d.evaluated \subseteq Tools
                 /\ (s.valid /\ d.mode = "fixed" => d.checked = Tools)
                 /\ (d.mode = "preserve" => d.registry = d.base /\ d.evaluated = {})
                 /\ d.evaluated \cap d.base = {}
                 /\ d.crashes <= MaxCrashes
SuccessPlain == Activate \/ FinishVM(TRUE) \/ FinishJournal(TRUE)
                \/ (\E tag \in s.receipts : JoinVM(tag)) \/ (\E tag \in s.journalReceipts : JoinJournal(tag)) \/ Joined
                \/ Initialize \/ PrepareWrite \/ Write \/ Sync \/ Publish \/ Intent \/ Dispatch
SuccessNext == DetailStart \/ (\E t \in Tools : CheckTool(t)) \/ DetailValidate
               \/ (SuccessPlain /\ UNCHANGED d)
SuccessSpec == DetailInit /\ [][SuccessNext]_allvars /\ WF_allvars(SuccessNext)
ReadyAndEffect == <> (s.phase = "ready" /\ s.g \in s.effects)
TerminalNext == DetailStart \/ (\E t \in Tools : CheckTool(t) \/ RejectCatalog(t))
                \/ DetailValidate \/ RejectInit \/ WriteFailure \/ SyncFailure
                \/ DetailReopen \/ (Plain /\ UNCHANGED d)
TerminalSpec == DetailInit /\ [][TerminalNext]_allvars /\ WF_allvars(TerminalNext)
FailureTerminality == (s.blocked ~> s.phase = "dead")
                     /\ (s.phase = "closing" ~> ~s.borrowed)
RecoveryNext == SuccessNext \/ DetailCrash \/ DetailReopen
RecoverySpec == DetailInit /\ [][RecoveryNext]_allvars /\ WF_allvars(RecoveryNext)
EventualReady == <>[] (s.phase = "ready")
=============================================================================
