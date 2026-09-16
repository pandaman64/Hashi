import Hashi
import Std.Data.HashMap

open Hashi

private def splitMix64 (x : UInt64) : UInt64 :=
  let z := x + 0x9e3779b97f4a7c15
  let z := (z ^^^ (z >>> 30)) * 0xbf58476d1ce4e5b9
  let z := (z ^^^ (z >>> 27)) * 0x94d049bb133111eb
  z ^^^ (z >>> 31)

private def makeKeys (n : Nat) (salt : UInt64) : Array UInt64 :=
  Array.ofFn fun i : Fin n => splitMix64 (UInt64.ofNat i.val + salt)

private def buildHashi (keys : Array UInt64) : HashMap UInt64 UInt64 := Id.run do
  let mut map : HashMap UInt64 UInt64 := {}
  for key in keys do
    map := map.insert key key
  return map

private def buildStd (keys : Array UInt64) : Std.HashMap UInt64 UInt64 := Id.run do
  let mut map : Std.HashMap UInt64 UInt64 := {}
  for key in keys do
    map := map.insert key key
  return map

private def lookupHashi (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 := Id.run do
  let mut sink := 0
  for _ in [:repetitions] do
    for key in keys do
      sink := sink ^^^ (map.get? key).getD 0
  return sink

private def lookupStd (map : Std.HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 := Id.run do
  let mut sink := 0
  for _ in [:repetitions] do
    for key in keys do
      sink := sink ^^^ (map[key]?).getD 0
  return sink

-- Opaque entry points keep the optimizer from specializing a benchmark down
-- to the small summary value that is printed after timing.
private opaque measuredBuildHashi (keys : Array UInt64) : HashMap UInt64 UInt64 :=
  buildHashi keys

private opaque measuredBuildStd (keys : Array UInt64) : Std.HashMap UInt64 UInt64 :=
  buildStd keys

private opaque measuredLookupHashi (map : HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 :=
  lookupHashi map keys repetitions

private opaque measuredLookupStd (map : Std.HashMap UInt64 UInt64) (keys : Array UInt64)
    (repetitions : Nat) : UInt64 :=
  lookupStd map keys repetitions

private def report (workload implementation : String) (operations elapsed : Nat) : IO Unit := do
  let nsPerOp := elapsed.toFloat / operations.toFloat
  IO.println s!"{workload},{implementation},{operations},{elapsed},{nsPerOp}"

private def timed (workload implementation : String) (operations : Nat)
    (action : Unit → IO UInt64) : IO UInt64 := do
  let start ← IO.monoNanosNow
  let sink ← action ()
  let elapsed := (← IO.monoNanosNow) - start
  report workload implementation operations elapsed
  return sink

private def parseNat (arg : Option String) (fallback : Nat) : Nat :=
  arg.bind String.toNat? |>.getD fallback

def main (args : List String) : IO Unit := do
  let n := parseNat args[0]? 65536
  let repetitions := parseNat args[1]? 20
  let hitKeys := makeKeys n 0
  let missKeys := makeKeys n 0xd1b54a32d192ed03
  IO.println "workload,implementation,operations,elapsed_ns,ns_per_op"

  let hashiInsertSink ← timed "insert_grow" "Hashi" n fun _ => do
    pure (measuredBuildHashi hitKeys).size.toUInt64
  let stdInsertSink ← timed "insert_grow" "Std.HashMap" n fun _ => do
    pure (measuredBuildStd hitKeys).size.toUInt64

  let hashi := measuredBuildHashi hitKeys
  let std := measuredBuildStd hitKeys
  let operations := n * repetitions
  let hashiHitSink ← timed "find_hit" "Hashi" operations fun _ => do
    pure (measuredLookupHashi hashi hitKeys repetitions)
  let stdHitSink ← timed "find_hit" "Std.HashMap" operations fun _ => do
    pure (measuredLookupStd std hitKeys repetitions)
  let hashiMissSink ← timed "find_miss" "Hashi" operations fun _ => do
    pure (measuredLookupHashi hashi missKeys repetitions)
  let stdMissSink ← timed "find_miss" "Std.HashMap" operations fun _ => do
    pure (measuredLookupStd std missKeys repetitions)

  IO.eprintln s!"sink={hashiInsertSink ^^^ stdInsertSink ^^^ hashiHitSink ^^^
    stdHitSink ^^^ hashiMissSink ^^^ stdMissSink}"
