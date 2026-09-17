import Hashi

open Hashi

@[extern "hashi_profile_control"]
private opaque setProfiling (enabled : UInt8) : IO Unit

private def splitMix64 (x : UInt64) : UInt64 :=
  let z := x + 0x9e3779b97f4a7c15
  let z := (z ^^^ (z >>> 30)) * 0xbf58476d1ce4e5b9
  let z := (z ^^^ (z >>> 27)) * 0x94d049bb133111eb
  z ^^^ (z >>> 31)

private def makeKeys (n : Nat) (salt : UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin n => splitMix64 (UInt64.ofNat i.val + salt)

private def fillMap (initial : HashMap UInt64 UInt64)
    (keys : Array UInt64) : HashMap UInt64 UInt64 := Id.run do
  let mut map := initial
  for key in keys do
    map := map.insert key key
  return map

private def buildMap (keys : Array UInt64) : HashMap UInt64 UInt64 :=
  fillMap {} keys

private def lookup (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 := Id.run do
  let mut sink := 0
  for _ in [:repetitions] do
    for key in keys do
      sink := sink ^^^ (map.get? key).getD 0
  return sink

-- IO-returning opaque boundaries prevent pure work from being moved across
-- the `moncontrol` calls by strict evaluation or compiler optimization.
private opaque profileLookupIO (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : IO UInt64 :=
  pure (lookup map keys repetitions)

private opaque profileBuildIO (keys : Array UInt64) : IO (HashMap UInt64 UInt64) :=
  pure (buildMap keys)

private opaque profileFillIO (initial : HashMap UInt64 UInt64)
    (keys : Array UInt64) : IO (HashMap UInt64 UInt64) :=
  pure (fillMap initial keys)

private opaque profileReserveIO (capacity : Nat) : IO (HashMap UInt64 UInt64) :=
  pure (HashMap.empty.reserve capacity)

private def profileInsertRepeated (keys : Array UInt64) (repetitions : Nat)
    (reserved : Bool) : IO UInt64 := do
  let mut sink := 0
  for _ in [:repetitions] do
    let initial ←
      if reserved then profileReserveIO keys.size
      else pure ({} : HashMap UInt64 UInt64)
    setProfiling 1
    let map ← profileFillIO initial keys
    setProfiling 0
    sink := sink ^^^ map.size.toUInt64
  return sink

private def parseNat (arg : Option String) (fallback : Nat) : Nat :=
  arg.bind String.toNat? |>.getD fallback

private def usage : String :=
  "usage: hashi_profile [find-hit|find-miss|insert-grow|insert-reserved] " ++
    "[elements] [repetitions]"

def main (args : List String) : IO Unit := do
  let workload := args[0]?.getD "find-hit"
  let n := parseNat args[1]? 262144
  let isInsert := workload == "insert-grow" || workload == "insert-reserved"
  let defaultRepetitions := if isInsert then 50 else 400
  let repetitions := parseNat args[2]? defaultRepetitions
  setProfiling 0
  let hitKeys := makeKeys n 0
  let sink ← match workload with
    | "find-hit" =>
      let map ← profileBuildIO hitKeys
      setProfiling 1
      let sink ← profileLookupIO map hitKeys repetitions
      setProfiling 0
      pure sink
    | "find-miss" =>
      let map ← profileBuildIO hitKeys
      let missKeys := makeKeys n 0xd1b54a32d192ed03
      setProfiling 1
      let sink ← profileLookupIO map missKeys repetitions
      setProfiling 0
      pure sink
    | "insert-grow" =>
      profileInsertRepeated hitKeys repetitions false
    | "insert-reserved" =>
      profileInsertRepeated hitKeys repetitions true
    | _ => throw (IO.userError usage)
  IO.eprintln s!"workload={workload} elements={n} repetitions={repetitions} sink={sink}"
