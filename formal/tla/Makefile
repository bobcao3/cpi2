SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := check

JAVA ?= java
TLA2TOOLS ?= $(HOME)/.cache/cpi-formal/tla2tools-1.7.4.jar
OUT ?= $(CURDIR)/../../.zig-cache/tla
TLC = $(JAVA) -XX:+UseParallelGC -Xmx1g -cp "$(TLA2TOOLS)" tlc2.TLC -workers 1 -fp 0 -lncheck final -coverage 1

LIFECYCLE := SessionSafety SessionLiveness RunSlots KeyedEffect
STARTUP := StartupSafety StartupSuccess StartupTerminal StartupRecovery
LIFECYCLE_NEGATIVE := NotificationBlocksCancel TerminalRelabel ReportingRelabel EarlyRelease FaultedAdmission ClosedAdmission TwoActive UnjoinedHost StaleContinuation OccupiedResume AliasedSlots OrphanedToken UnsyncedDispatch PartialReceipt UnexecutedReceipt BlindReplay
STARTUP_NEGATIVE := UnsyncedPublish ProvisionalDispatch StaleJoinVM StaleJoinJournal UnjoinedRelease LiveRuntimeRelease TornRetainedCrash
POSITIVE := $(LIFECYCLE) $(STARTUP)
NEGATIVE := $(LIFECYCLE_NEGATIVE) $(STARTUP_NEGATIVE)

.PHONY: check check-lifecycle check-startup tools $(POSITIVE) $(NEGATIVE)
check: check-lifecycle check-startup
check-lifecycle: $(LIFECYCLE) $(LIFECYCLE_NEGATIVE)
check-startup: $(STARTUP) $(STARTUP_NEGATIVE)

tools:
	@test -f "$(TLA2TOOLS)" || { echo 'Set TLA2TOOLS to the TLA+ tools 1.7.4 jar.' >&2; exit 1; }
	@printf '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88  %s\n' "$(TLA2TOOLS)" | sha256sum --check --status

SessionSafety SessionLiveness NotificationBlocksCancel: MODEL = SessionLifecycle
RunSlots: MODEL = RunSlots
KeyedEffect: MODEL = KeyedEffect
$(STARTUP): MODEL = StartupFinite
TerminalRelabel ReportingRelabel EarlyRelease FaultedAdmission ClosedAdmission TwoActive UnjoinedHost: MODEL = SessionLifecycleFaults
StaleContinuation OccupiedResume AliasedSlots OrphanedToken: MODEL = RunSlotsFaults
UnsyncedDispatch PartialReceipt UnexecutedReceipt BlindReplay: MODEL = KeyedEffectFaults
$(STARTUP_NEGATIVE): MODEL = StartupFaults

$(POSITIVE): tools
	@mkdir -p "$(OUT)/$@"
	@$(TLC) -metadir "$(OUT)/$@/states" -config "$@.cfg" "$(MODEL).tla" > "$(OUT)/$@/tlc.log" 2>&1 || { tail -50 "$(OUT)/$@/tlc.log"; exit 1; }
	@grep -Fq 'Model checking completed. No error has been found.' "$(OUT)/$@/tlc.log"
	@printf 'PASS %s\n' '$@'

$(NEGATIVE): CONFIG = negative/$@.cfg
$(NEGATIVE): EXIT = 12
$(NEGATIVE): MESSAGE = Invariant $(RULE) is violated.
NotificationBlocksCancel: RULE = CancelAvailable
TerminalRelabel: RULE = TerminalImmutable
ReportingRelabel: RULE = ReportingPreservesCompletion
EarlyRelease: RULE = JoinedRelease
FaultedAdmission: RULE = NoExecutionWhenUnhealthy
ClosedAdmission: RULE = ClosedAdmission
TwoActive: RULE = OneActive
StaleContinuation: RULE = NoStaleResume
OccupiedResume: RULE = NoLostRun
AliasedSlots: RULE = ExclusiveSlots
OrphanedToken: RULE = TokenOwned
UnsyncedDispatch: RULE = DurableBeforeDispatch
PartialReceipt: RULE = KnownReceiptOnly
UnexecutedReceipt: RULE = ReceiptRequiresExecution
BlindReplay: RULE = NoBlindReplay
UnsyncedPublish: RULE = NoEarlyPublication
ProvisionalDispatch: RULE = NoEarlyEffect
StaleJoinVM StaleJoinJournal: RULE = NoStaleInstall
UnjoinedRelease: RULE = JoinedRelease
LiveRuntimeRelease: RULE = NoLiveRuntimeRelease
TornRetainedCrash: RULE = TailSafety
UnjoinedHost: EXIT = 13
UnjoinedHost: MESSAGE = Temporal properties were violated.

$(NEGATIVE): tools
	@mkdir -p "$(OUT)/$@"
	@result=0; $(TLC) -metadir "$(OUT)/$@/states" -config "$(CONFIG)" "$(MODEL).tla" > "$(OUT)/$@/tlc.log" 2>&1 || result=$$?; \
		if test "$$result" -ne "$(EXIT)" || ! grep -Fq '$(MESSAGE)' "$(OUT)/$@/tlc.log"; then \
			tail -50 "$(OUT)/$@/tlc.log"; exit 1; \
		fi
	@printf 'EXPECTED COUNTEREXAMPLE %s\n' '$@'
