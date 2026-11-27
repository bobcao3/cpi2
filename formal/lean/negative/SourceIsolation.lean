import Cpi.Registry

open Cpi.Registry

example : plan (plan empty collisionLeft) collisionRight 0 =
    plan (plan empty collisionRight) collisionLeft 0 := by
  decide
