import Std

set_option autoImplicit false

namespace Cpi.Publication

universe u

structure Candidate (Payload : Type u) where
  owner : Nat
  transaction : Nat
  payload : Payload
  deriving DecidableEq, Repr

inductive Phase (Payload : Type u) where
  | idle
  | prepared (candidate : Candidate Payload)
  | synced (candidate : Candidate Payload)
  | uncertain
  deriving DecidableEq, Repr

structure State (Payload : Type u) where
  worker : Nat
  visible : Candidate Payload
  durable : List (Candidate Payload)
  phase : Phase Payload

inductive Action (Payload : Type u) where
  | prepare (candidate : Candidate Payload)
  | syncSuccess
  | rejectBeforeAppend
  | syncUncertain
  | publish
  | replaceOwner

variable {Payload : Type u}

def initial (payload : Payload) : State Payload :=
  let baseline : Candidate Payload := ⟨0, 0, payload⟩
  ⟨0, baseline, [baseline], .idle⟩

def step (state : State Payload) : Action Payload → State Payload
  | .prepare candidate =>
    match state.phase with
    | .uncertain => state
    | _ =>
      if candidate.owner = state.worker then { state with phase := .prepared candidate }
      else state
  | .syncSuccess =>
    match state.phase with
    | .prepared candidate =>
      { state with phase := .synced candidate, durable := candidate :: state.durable }
    | _ => state
  | .rejectBeforeAppend =>
    match state.phase with
    | .prepared _ => { state with phase := .idle }
    | _ => state
  | .syncUncertain =>
    match state.phase with
    | .prepared _ => { state with phase := .uncertain }
    | _ => state
  | .publish =>
    match state.phase with
    | .synced candidate =>
      if candidate.owner = state.worker then
        { state with visible := candidate, phase := .idle }
      else state
    | _ => state
  | .replaceOwner => { state with worker := state.worker + 1, phase := .idle }

def Safe (state : State Payload) : Prop :=
  state.visible ∈ state.durable ∧
  match state.phase with
  | .synced candidate => candidate ∈ state.durable
  | _ => True

inductive Reachable (payload : Payload) : State Payload → Prop where
  | init : Reachable payload (initial payload)
  | next {state : State Payload} (reachable : Reachable payload state)
      (action : Action Payload) : Reachable payload (step state action)

theorem initial_safe (payload : Payload) : Safe (initial payload) := by
  simp [Safe, initial]

theorem step_preserves_safe (state : State Payload) (action : Action Payload)
    (safe : Safe state) : Safe (step state action) := by
  cases action <;> cases phase : state.phase <;> simp_all [step, Safe]
  all_goals split <;> simp_all

theorem reachable_safe (payload : Payload) (state : State Payload)
    (reachable : Reachable payload state) : Safe state := by
  induction reachable with
  | init => exact initial_safe payload
  | next previous action invariant => exact step_preserves_safe _ action invariant

theorem visible_has_sync_receipt (payload : Payload) (state : State Payload)
    (reachable : Reachable payload state) : state.visible ∈ state.durable :=
  (reachable_safe payload state reachable).1

theorem stale_publication_rejected (state : State Payload) (candidate : Candidate Payload)
    (synced : state.phase = .synced candidate) (stale : candidate.owner ≠ state.worker) :
    step state .publish = state := by
  simp [step, synced, stale]

theorem uncertain_blocks_prepare (state : State Payload) (candidate : Candidate Payload)
    (uncertain : state.phase = .uncertain) : step state (.prepare candidate) = state := by
  simp [step, uncertain]

theorem uncertain_blocks_sync (state : State Payload)
    (uncertain : state.phase = .uncertain) : step state .syncSuccess = state := by
  simp [step, uncertain]

theorem uncertain_blocks_publication (state : State Payload)
    (uncertain : state.phase = .uncertain) : step state .publish = state := by
  simp [step, uncertain]

theorem known_receipts_preserved (state : State Payload) (action : Action Payload)
    (candidate : Candidate Payload) (known : candidate ∈ state.durable) :
    candidate ∈ (step state action).durable := by
  cases action <;> cases phase : state.phase <;> simp_all [step]
  all_goals split <;> simp_all

#print axioms initial_safe
#print axioms step_preserves_safe
#print axioms reachable_safe
#print axioms visible_has_sync_receipt
#print axioms stale_publication_rejected
#print axioms uncertain_blocks_prepare
#print axioms uncertain_blocks_sync
#print axioms uncertain_blocks_publication
#print axioms known_receipts_preserved

end Cpi.Publication
