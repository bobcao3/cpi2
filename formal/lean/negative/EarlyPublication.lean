import Cpi.Publication

open Cpi.Publication

def unpublished : State Nat :=
  { initial 0 with visible := ⟨0, 1, 99⟩, phase := .prepared ⟨0, 1, 99⟩ }

example : Safe unpublished := by
  unfold Safe unpublished initial
  decide
