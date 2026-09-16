import Hashi

open Hashi

private def splitMix64 (x : UInt64) : UInt64 :=
  let z := x + 0x9e3779b97f4a7c15
  let z := (z ^^^ (z >>> 30)) * 0xbf58476d1ce4e5b9
  let z := (z ^^^ (z >>> 27)) * 0x94d049bb133111eb
  z ^^^ (z >>> 31)

private def makeKeys (n : Nat) (salt : UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin n => splitMix64 (UInt64.ofNat i.val + salt)

private def buildMap (keys : Array UInt64) : HashMap UInt64 UInt64 := Id.run do
  let mut map : HashMap UInt64 UInt64 := {}
  for key in keys do
    map := map.insert key key
  return map

private def lookup (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 := Id.run do
  let mut sink := 0
  for _ in [:repetitions] do
    for key in keys do
      sink := sink ^^^ (map.get? key).getD 0
  return sink

private def insertRepeated (keys : Array UInt64) (repetitions : Nat) : UInt64 := Id.run do
  let mut sink := 0
  for _ in [:repetitions] do
    let map := buildMap keys
    sink := sink ^^^ map.size.toUInt64
  return sink

-- Keep profiling workloads as stable, separately visible native symbols.
private opaque profileLookup (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 :=
  lookup map keys repetitions

private opaque profileInsert (keys : Array UInt64) (repetitions : Nat) : UInt64 :=
  insertRepeated keys repetitions

private def parseNat (arg : Option String) (fallback : Nat) : Nat :=
  arg.bind String.toNat? |>.getD fallback

private def usage : String :=
  "usage: hashi_profile [find-hit|find-miss|insert-grow] [elements] [repetitions]"

def main (args : List String) : IO Unit := do
  let workload := args[0]?.getD "find-hit"
  let n := parseNat args[1]? 262144
  let defaultRepetitions := if workload == "insert-grow" then 20 else 400
  let repetitions := parseNat args[2]? defaultRepetitions
  let hitKeys := makeKeys n 0
  let sink ← match workload with
    | "find-hit" =>
      let map := buildMap hitKeys
      pure (profileLookup map hitKeys repetitions)
    | "find-miss" =>
      let map := buildMap hitKeys
      let missKeys := makeKeys n 0xd1b54a32d192ed03
      pure (profileLookup map missKeys repetitions)
    | "insert-grow" =>
      pure (profileInsert hitKeys repetitions)
    | _ => throw (IO.userError usage)
  IO.eprintln s!"workload={workload} elements={n} repetitions={repetitions} sink={sink}"
