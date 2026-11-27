import Std

set_option autoImplicit false

namespace Cpi.Lifetime

structure State where
  closing : Bool
  released : Bool
  jobs : List Nat
  waiters : List Nat
  deriving DecidableEq, Repr

inductive Action where
  | startJob (id : Nat)
  | terminalResult (id : Nat)
  | joinJob (id : Nat)
  | cancelWaiter (id : Nat)
  | close
  | release

def initial : State := ⟨false, false, [], []⟩

def step (state : State) : Action → State
  | .startJob id =>
    if state.closing = true ∨ id ∈ state.jobs then state
    else { state with jobs := id :: state.jobs }
  | .terminalResult _ => state
  | .joinJob id => { state with jobs := state.jobs.erase id }
  | .cancelWaiter id => { state with waiters := state.waiters.erase id }
  | .close => { state with closing := true }
  | .release =>
    if state.closing = true ∧ state.jobs = [] then { state with released := true }
    else state

def Safe (state : State) : Prop :=
  state.released = true → state.closing = true ∧ state.jobs = []

inductive Reachable : State → Prop where
  | init : Reachable initial
  | next {state : State} (reachable : Reachable state) (action : Action) :
      Reachable (step state action)

theorem initial_safe : Safe initial := by
  simp [Safe, initial]

theorem step_preserves_safe (state : State) (action : Action) (safe : Safe state) :
    Safe (step state action) := by
  cases action <;> simp_all [step, Safe]
  all_goals split <;> simp_all

theorem release_is_joined (state : State) (reachable : Reachable state) : Safe state := by
  induction reachable with
  | init => exact initial_safe
  | next previous action invariant => exact step_preserves_safe _ action invariant

theorem closed_admission (state : State) (id : Nat) (closed : state.closing = true) :
    step state (.startJob id) = state := by
  simp [step, closed]

theorem duplicate_start_coalesces (state : State) (id : Nat) (owned : id ∈ state.jobs) :
    step state (.startJob id) = state := by
  simp [step, owned]

#print axioms initial_safe
#print axioms step_preserves_safe
#print axioms release_is_joined
#print axioms closed_admission
#print axioms duplicate_start_coalesces

end Cpi.Lifetime
