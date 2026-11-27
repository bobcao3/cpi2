import Std

set_option autoImplicit false

namespace Cpi.Registry

universe u v w

structure Entry (Source : Type v) (Payload : Type w) where
  source : Source
  payload : Payload
  deriving DecidableEq, Repr

abbrev Store (Name : Type u) (Source : Type v) (Payload : Type w) :=
  Name → Option (Entry Source Payload)

structure Batch (Name : Type u) (Source : Type v) (Payload : Type w) where
  source : Source
  replaceSource : Bool := false
  remove : List Name := []
  assign : List (Name × Payload) := []

variable {Name : Type u} {Source : Type v} {Payload : Type w}
variable [DecidableEq Name] [DecidableEq Source]

def latest (name : Name) : List (Name × Payload) → Option Payload
  | [] => none
  | (key, value) :: rest =>
    match latest name rest with
    | some later => some later
    | none => if name = key then some value else none

def retain (batch : Batch Name Source Payload) (name : Name)
    (previous : Option (Entry Source Payload)) : Option (Entry Source Payload) :=
  if name ∈ batch.remove then none else
    match previous with
    | none => none
    | some entry =>
      if batch.replaceSource = true ∧ entry.source = batch.source then none else some entry

def plan (previous : Store Name Source Payload) (batch : Batch Name Source Payload) :
    Store Name Source Payload := fun name =>
  match latest name batch.assign with
  | some value => some ⟨batch.source, value⟩
  | none => retain batch name (previous name)

theorem retain_idempotent (batch : Batch Name Source Payload) (name : Name)
    (previous : Option (Entry Source Payload)) :
    retain batch name (retain batch name previous) = retain batch name previous := by
  by_cases removed : name ∈ batch.remove
  · simp [retain, removed]
  · cases previous with
    | none => simp [retain, removed]
    | some entry =>
      by_cases replaced : batch.replaceSource = true ∧ entry.source = batch.source
      · simp [retain, removed, replaced]
      · simp [retain, removed, replaced]

theorem plan_idempotent (previous : Store Name Source Payload)
    (batch : Batch Name Source Payload) :
    plan (plan previous batch) batch = plan previous batch := by
  funext name
  cases h : latest name batch.assign <;> simp [plan, h, retain_idempotent]

theorem assigned_value (previous : Store Name Source Payload)
    (batch : Batch Name Source Payload) (name : Name) (value : Payload)
    (assigned : latest name batch.assign = some value) :
    plan previous batch name = some ⟨batch.source, value⟩ := by
  simp [plan, assigned]

theorem explicit_removal (previous : Store Name Source Payload)
    (batch : Batch Name Source Payload) (name : Name)
    (unassigned : latest name batch.assign = none) (removed : name ∈ batch.remove) :
    plan previous batch name = none := by
  simp [plan, unassigned, retain, removed]

theorem source_replacement (previous : Store Name Source Payload)
    (batch : Batch Name Source Payload) (name : Name) (entry : Entry Source Payload)
    (old : previous name = some entry) (unassigned : latest name batch.assign = none)
    (replacing : batch.replaceSource = true) (sameSource : entry.source = batch.source) :
    plan previous batch name = none := by
  simp [plan, unassigned, retain, old, replacing, sameSource]

theorem unrelated_key_preserved (previous : Store Name Source Payload)
    (batch : Batch Name Source Payload) (name : Name) (entry : Entry Source Payload)
    (old : previous name = some entry) (unassigned : latest name batch.assign = none)
    (notRemoved : name ∉ batch.remove)
    (notReplaced : ¬(batch.replaceSource = true ∧ entry.source = batch.source)) :
    plan previous batch name = some entry := by
  simp [plan, unassigned, retain, old, notRemoved, notReplaced]

def collisionLeft : Batch Nat Nat Nat := { source := 1, assign := [(0, 10)] }
def collisionRight : Batch Nat Nat Nat := { source := 2, assign := [(0, 20)] }
def empty : Store Nat Nat Nat := fun _ => none

theorem distinct_sources_can_overwrite :
    plan (plan empty collisionLeft) collisionRight 0 ≠
      plan (plan empty collisionRight) collisionLeft 0 := by
  decide

#print axioms retain_idempotent
#print axioms plan_idempotent
#print axioms assigned_value
#print axioms explicit_removal
#print axioms source_replacement
#print axioms unrelated_key_preserved
#print axioms distinct_sources_can_overwrite

end Cpi.Registry
