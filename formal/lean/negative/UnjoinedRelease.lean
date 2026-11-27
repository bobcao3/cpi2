import Cpi.Lifetime

open Cpi.Lifetime

example : Safe ⟨true, true, [7], []⟩ := by
  unfold Safe
  decide
