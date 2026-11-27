------------------------------ MODULE Startup ------------------------------
EXTENDS Naturals, FiniteSets
VARIABLES journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined
s == [journalReceipts |-> journalReceipts, g |-> g, phase |-> phase, vm |-> vm, jr |-> jr, vg |-> vg, jg |-> jg, vo |-> vo, jo |-> jo, borrowed |-> borrowed, blocked |-> blocked, valid |-> valid, initialized |-> initialized, wrote |-> wrote, synced |-> synced, complete |-> complete, stable |-> stable, published |-> published, effects |-> effects, intents |-> intents, failed |-> failed, canceled |-> canceled, joined |-> joined, released |-> released, installs |-> installs, receipts |-> receipts, validated |-> validated, initializedHistory |-> initializedHistory, runtime |-> runtime, runtimeStarted |-> runtimeStarted, runtimeJoined |-> runtimeJoined]
vars == <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Phases == {"idle", "prep", "stage", "write", "sync", "ready", "closing", "dead"}
Jobs == {"none", "running", "done", "joined"}
Owners == {"none", "task", "startup"}
MayStart(generation) == TRUE
IsPrefix(a, b) == a \subseteq b /\ \A i \in a : \A j \in b \ a : i < j

Init == /\ journalReceipts = {}
        /\ g = 0
        /\ phase = "idle"
        /\ vm = "none"
        /\ jr = "none"
        /\ vg = 0
        /\ jg = 0
        /\ vo = "none"
        /\ jo = "none"
        /\ borrowed = FALSE
        /\ blocked = FALSE
        /\ valid = FALSE
        /\ initialized = FALSE
        /\ wrote = FALSE
        /\ synced = FALSE
        /\ complete = {}
        /\ stable = {}
        /\ published = {}
        /\ effects = {}
        /\ intents = {}
        /\ failed = {}
        /\ canceled = {}
        /\ joined = {}
        /\ released = {}
        /\ installs = {}
        /\ receipts = {}
        /\ validated = {} /\ initializedHistory = {}
        /\ runtime = "none" /\ runtimeStarted = {} /\ runtimeJoined = {}

Start == /\ phase \in {"idle", "dead"}
         /\ MayStart(g)
         /\ g' = (g + 1)
              /\ phase' = ("prep")
              /\ vm' = ("running")
              /\ jr' = ("running")
              /\ vg' = (g + 1)
              /\ jg' = (g + 1)
              /\ vo' = ("task")
              /\ jo' = ("task")
              /\ borrowed' = (TRUE)
              /\ blocked' = (FALSE)
              /\ valid' = (FALSE)
              /\ initialized' = (FALSE)
              /\ wrote' = (FALSE)
              /\ synced' = (FALSE)
              /\ UNCHANGED <<journalReceipts, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
FinishVM(ok) == /\ vm = "running"
                /\ vm' = ("done")
              /\ receipts' = (receipts \cup {g})
              /\ blocked' = (blocked \/ ~ok)
              /\ failed' = (IF ok THEN failed ELSE failed \cup {g})
              /\ UNCHANGED <<journalReceipts, g, phase, jr, vg, jg, vo, jo, borrowed, valid, initialized, wrote, synced, complete, stable, published, effects, intents, canceled, joined, released, installs, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
FinishJournal(ok) == /\ jr = "running"
                     /\ jr' = ("done")
              /\ journalReceipts' = journalReceipts \cup {g}
              /\ blocked' = (blocked \/ ~ok)
              /\ failed' = (IF ok THEN failed ELSE failed \cup {g})
              /\ UNCHANGED << g, phase, vm, vg, jg, vo, jo, borrowed, valid, initialized, wrote, synced, complete, stable, published, effects, intents, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
JoinVM(tag) == /\ vm = "done" /\ tag \in receipts /\ tag = g
          /\ vm' = ("joined")
              /\ vo' = ("startup")
              /\ joined' = (IF jr = "joined" THEN joined \cup {g} ELSE joined)
              /\ installs' = (installs \cup {<<g, tag>>})
              /\ UNCHANGED <<journalReceipts, g, phase, jr, vg, jg, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, released, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
JoinJournal(tag) == /\ jr = "done" /\ tag \in journalReceipts /\ tag = g
               /\ jr' = ("joined")
              /\ jo' = ("startup")
              /\ joined' = (IF vm = "joined" THEN joined \cup {g} ELSE joined)
              /\ installs' = (installs \cup {<<g, tag>>})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, vg, jg, vo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, released, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Joined == /\ phase = "prep" /\ vm = "joined" /\ jr = "joined"
          /\ ~blocked
          /\ phase' = ("stage")
              /\ joined' = (joined \cup {g})
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Validate == /\ phase = "stage" /\ ~blocked /\ ~valid
            /\ valid' = (TRUE)
              /\ validated' = validated \cup {g}
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Initialize == /\ phase = "stage" /\ ~blocked /\ valid
              /\ ~initialized
              /\ initialized' = (TRUE)
              /\ initializedHistory' = initializedHistory \cup {g}
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, runtime, runtimeStarted, runtimeJoined>>
PrepareWrite == /\ phase = "stage" /\ ~blocked
                /\ valid /\ initialized
                /\ phase' = ("write")
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Write == /\ phase = "write" /\ ~blocked
         /\ phase' = ("sync")
              /\ wrote' = (TRUE)
              /\ complete' = (complete \cup {g})
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, synced, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Sync == /\ phase = "sync" /\ ~blocked
        /\ synced' = (TRUE)
              /\ stable' = (complete)
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, complete, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Publish == /\ phase = "sync" /\ ~blocked /\ synced /\ runtime = "waiting"
           /\ phase' = ("ready")
              /\ published' = (published \cup {g})
              /\ runtime' = "active"
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>
Intent == /\ phase = "ready" /\ ~blocked
          /\ intents' = (intents \cup {g})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Dispatch == /\ phase = "ready" /\ ~blocked /\ g \in intents
            /\ effects' = (effects \cup {g})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Fail == /\ phase \in {"stage", "write", "sync"} /\ ~blocked
        /\ blocked' = (TRUE)
              /\ failed' = (failed \cup {g})
              /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, valid, initialized, wrote, synced, complete, stable, published, effects, intents, canceled, joined, released, installs, receipts, validated, initializedHistory, runtime, runtimeStarted, runtimeJoined>>
Close == /\ phase \in {"prep", "stage", "write", "sync", "ready"}
         /\ phase' = ("closing")
              /\ blocked' = (TRUE)
              /\ canceled' = (IF g \in published THEN canceled ELSE canceled \cup {g})
              /\ runtime' = (IF runtime \in {"waiting", "active"} THEN "draining" ELSE runtime)
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>
Release == /\ runtime \in {"none", "joined"}
           /\ phase = "closing" /\ vm = "joined" /\ jr = "joined"
           /\ phase' = ("dead")
              /\ borrowed' = (FALSE)
              /\ vo' = ("none")
              /\ jo' = ("none")
              /\ released' = (released \cup {g})
              /\ runtime' = "none"
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>
Abort == /\ phase \in {"prep", "stage", "write", "sync"} /\ blocked
         /\ phase' = ("closing")
              /\ runtime' = (IF runtime \in {"waiting", "active"} THEN "draining" ELSE runtime)
              /\ UNCHANGED <<journalReceipts, g, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>
Crash(keep) == /\ phase \notin {"idle", "dead"}
               /\ IsPrefix(stable, keep) /\ IsPrefix(keep, complete)
               /\ phase' = ("dead")
              /\ vm' = ("none")
              /\ jr' = ("none")
              /\ vo' = ("none")
              /\ jo' = ("none")
              /\ borrowed' = (FALSE)
              /\ blocked' = (TRUE)
              /\ valid' = (FALSE)
              /\ initialized' = (FALSE)
              /\ wrote' = (FALSE)
              /\ synced' = (FALSE)
              /\ complete' = (keep)
              /\ runtime' = "none"
              /\ UNCHANGED <<journalReceipts, g, vg, jg, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted, runtimeJoined>>
Reopen == /\ phase = "dead" /\ UNCHANGED vars

Activate == /\ phase = "sync" /\ ~blocked /\ runtime = "none"
            /\ runtime' = "waiting" /\ runtimeStarted' = runtimeStarted \cup {g}
            /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeJoined>>
JoinRuntime == /\ phase = "closing" /\ runtime = "draining"
               /\ runtime' = "joined" /\ runtimeJoined' = runtimeJoined \cup {g}
               /\ UNCHANGED <<journalReceipts, g, phase, vm, jr, vg, jg, vo, jo, borrowed, blocked, valid, initialized, wrote, synced, complete, stable, published, effects, intents, failed, canceled, joined, released, installs, receipts, validated, initializedHistory, runtimeStarted>>

Next == Activate \/ JoinRuntime \/ Start \/ (\E ok \in BOOLEAN : FinishVM(ok) \/ FinishJournal(ok))
        \/ (\E tag \in receipts : JoinVM(tag)) \/ (\E tag \in journalReceipts : JoinJournal(tag)) \/ Joined \/ Validate \/ Initialize
        \/ PrepareWrite \/ Write \/ Sync \/ Publish \/ Intent \/ Dispatch
        \/ Fail \/ Close \/ Release \/ Abort
        \/ (\E keep \in SUBSET complete : Crash(keep)) \/ Reopen
Spec == Init /\ [][Next]_vars

TypeOK == /\ journalReceipts \subseteq Nat
          /\ runtime \in {"none", "waiting", "active", "draining", "joined"}
          /\ runtimeStarted \subseteq Nat /\ runtimeJoined \subseteq Nat
          /\ g \in Nat
          /\ phase \in Phases
          /\ vm \in Jobs
          /\ jr \in Jobs
          /\ vg \in Nat
          /\ jg \in Nat
          /\ vo \in Owners
          /\ jo \in Owners
          /\ borrowed \in BOOLEAN
          /\ blocked \in BOOLEAN
          /\ valid \in BOOLEAN
          /\ initialized \in BOOLEAN
          /\ wrote \in BOOLEAN
          /\ synced \in BOOLEAN
          /\ complete \in SUBSET Nat
          /\ stable \in SUBSET Nat
          /\ published \in SUBSET Nat
          /\ effects \in SUBSET Nat
          /\ intents \in SUBSET Nat
          /\ failed \in SUBSET Nat
          /\ canceled \in SUBSET Nat
          /\ joined \in SUBSET Nat
          /\ released \in SUBSET Nat
          /\ installs \in SUBSET (Nat \X Nat)
          /\ receipts \in SUBSET Nat
          /\ validated \subseteq Nat /\ initializedHistory \subseteq Nat
Local == /\ (runtime \in {"waiting", "active", "draining", "joined"} => g \in runtimeStarted)
         /\ (runtime = "joined" => g \in runtimeJoined)
         /\ (g \in runtimeStarted /\ phase # "dead" => runtime # "none")
         /\ (g \in released => phase = "dead")
         /\ (phase = "ready" => runtime = "active")
         /\ (phase \in {"idle", "dead"} => runtime = "none")
         /\ (runtime = "active" => phase = "ready")
         /\ (runtime = "waiting" => phase = "sync")
         /\ (runtime \in {"draining", "joined"} => phase = "closing")
         /\ vg = g /\ jg = g
         /\ (vm = "running" \/ vm = "done" => vo = "task")
         /\ (jr = "running" \/ jr = "done" => jo = "task")
         /\ (vo = "startup" => vm = "joined")
         /\ (jo = "startup" => jr = "joined")
         /\ (phase \notin {"idle", "dead"} => borrowed)
         /\ (phase \in {"stage", "write", "sync", "ready"} =>
               vm = "joined" /\ jr = "joined" /\ g \in joined)
         /\ (initialized => valid)
         /\ (valid => g \in validated)
         /\ (initialized => g \in initializedHistory)
         /\ (phase \in {"idle", "dead"} => vm \in {"none", "joined"} /\ jr \in {"none", "joined"} /\ vo = "none" /\ jo = "none")
         /\ (phase \in {"write", "sync", "ready"} => initialized)
         /\ (phase \in {"sync", "ready"} => wrote /\ g \in complete)
         /\ (synced => g \in stable)
         /\ (phase = "ready" => synced /\ g \in published)
         /\ (g \in failed \cup canceled => blocked)
         /\ (blocked => phase # "ready")
         /\ (g \in published => valid \/ phase = "dead")
         /\ (g \in published => phase \in {"ready", "closing", "dead"})
         /\ (g \in published /\ phase # "dead" => vm = "joined" /\ jr = "joined")
         /\ (phase = "prep" => ~valid /\ ~initialized /\ ~wrote /\ ~synced)
         /\ (phase \in {"idle", "dead"} => ~borrowed)
         /\ (vm = "joined" /\ jr = "joined" => g \in joined)
         /\ (phase \in {"prep", "stage", "write"} => g \notin complete)
History == /\ released \cap runtimeStarted \subseteq runtimeJoined
           /\ published \subseteq runtimeStarted
           /\ published \subseteq stable
           /\ effects \subseteq intents /\ intents \subseteq published
           /\ published \subseteq joined
           /\ published \subseteq validated /\ published \subseteq initializedHistory
           /\ published \cap (failed \cup canceled) = {}
           /\ released \subseteq joined
           /\ \A h \in installs : h[1] = h[2]
           /\ \A i \in published \cup failed \cup canceled \cup joined
                        \cup released \cup intents \cup effects \cup receipts
                        \cup validated \cup initializedHistory \cup runtimeStarted \cup runtimeJoined \cup journalReceipts : i <= g
Prefix == /\ IsPrefix(stable, complete)
          /\ \A i \in complete : i <= g
Inv == TypeOK /\ Local /\ History /\ Prefix
NoEarlyPublication == published \subseteq stable /\ published \subseteq joined
                      /\ published \subseteq validated /\ published \subseteq initializedHistory
NoEarlyEffect == effects \subseteq intents /\ intents \subseteq published
NoFailedPublication == published \cap (failed \cup canceled) = {}
NoStaleInstall == \A h \in installs : h[1] = h[2]
JoinedRelease == released \subseteq joined
NoLiveRuntimeRelease == released \cap runtimeStarted \subseteq runtimeJoined
ExclusiveOwnership == vo \in Owners /\ jo \in Owners
                      /\ (vm \in {"running", "done"} => vo = "task" /\ borrowed)
                      /\ (jr \in {"running", "done"} => jo = "task" /\ borrowed)
Safety == NoLiveRuntimeRelease /\ ExclusiveOwnership /\ NoEarlyPublication /\ NoEarlyEffect /\ NoFailedPublication
          /\ NoStaleInstall /\ JoinedRelease /\ Prefix
=============================================================================
