import Hashi
import Std.Data.HashMap

open Hashi

private def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def testGroups : IO Unit := do
  let ctrl := ByteArray.mk #[0x12, 0xff, 0x80, 0x12, 0x7f, 0xff, 0x00, 0x12]
  ensure (Swiss.Group.matchH2 ctrl 0 0x12 == 0x89) "matchH2 mask is incorrect"
  ensure (Swiss.Group.matchEmpty ctrl 0 == 0x22) "matchEmpty mask is incorrect"
  ensure (Swiss.Group.matchH2AndEmpty ctrl 0 0x12 == 0x2289)
    "combined H2/EMPTY mask is incorrect"
  ensure (Swiss.Group.matchEmptyOrDeleted ctrl 0 == 0x26)
    "matchEmptyOrDeleted mask is incorrect"
  ensure (Swiss.Group.ctz 0x80 == 7 && Swiss.Group.ctz 0 == 32) "ctz is incorrect"

private def testNativeParity : IO Unit := do
  let mut ctrl := ByteArray.emptyWithCapacity 64
  for i in [:64] do
    let value : UInt8 :=
      if i % 11 == 0 then Swiss.Ctrl.empty
      else if i % 13 == 0 then Swiss.Ctrl.deleted
      else UInt8.ofNat (i * 37 % 128)
    ctrl := ctrl.push value
  for pos in [:57] do
    let p := USize.ofNat pos
    ensure (Swiss.Group.matchEmpty ctrl p == Swiss.Group.Portable.matchEmpty ctrl p)
      s!"native empty mismatch at {pos}"
    ensure (Swiss.Group.matchEmptyOrDeleted ctrl p ==
      Swiss.Group.Portable.matchEmptyOrDeleted ctrl p) s!"native special mismatch at {pos}"
    ensure (Swiss.Group.anyEmpty ctrl p == Swiss.Group.Portable.anyEmpty ctrl p)
      s!"native anyEmpty mismatch at {pos}"
    for tag in [:128] do
      let t := UInt8.ofNat tag
      ensure (Swiss.Group.matchH2 ctrl p t == Swiss.Group.Portable.matchH2 ctrl p t)
        s!"native H2 mismatch at {pos}, tag {tag}"
      ensure (Swiss.Group.matchH2AndEmpty ctrl p t ==
        Swiss.Group.Portable.matchH2AndEmpty ctrl p t)
        s!"native combined mask mismatch at {pos}, tag {tag}"
  for bits in [:256] do
    let b := UInt32.ofNat bits
    ensure (Swiss.Group.ctz b == Swiss.Group.Portable.ctz b)
      s!"native ctz mismatch for {bits}"

private def testBasic : IO Unit := do
  let mut m : HashMap Nat Nat := {}
  ensure (m.isEmpty && m.isValid) "empty map is invalid"
  m := m.insert 1 10
  m := m.insert 2 20
  m := m.insert 1 11
  ensure (m.size == 2 && m.get? 1 == some 11 && m.get? 3 == none)
    "basic insertion or lookup failed"
  m := m.erase 1
  ensure (m.size == 1 && m.get? 1 == none && m.get? 2 == some 20 && m.isValid)
    "basic erase failed"
  m := m.reserve 1000
  ensure (m.capacity >= 1000 && m.get? 2 == some 20 && m.isValid) "reserve failed"

private structure Colliding where
  value : Nat
deriving BEq, Inhabited

private instance : Hashable Colliding where
  hash _ := 0

private def testCollisions : IO Unit := do
  let mut m : HashMap Colliding Nat := {}
  for i in [:300] do
    m := m.insert ⟨i⟩ (i * 3)
  ensure (m.size == 300 && m.isValid) "collision-heavy map is invalid"
  for i in [:300] do
    ensure (m.get? ⟨i⟩ == some (i * 3)) s!"collision lookup failed for {i}"
  for i in [:150] do
    m := m.erase ⟨i * 2⟩
  ensure (m.size == 150 && m.isValid) "collision erase broke invariants"
  for i in [:300] do
    let expected := if i % 2 == 0 then none else some (i * 3)
    ensure (m.get? ⟨i⟩ == expected) s!"collision erase lookup failed for {i}"

private def nextRandom (state : UInt64) : UInt64 :=
  state * 6364136223846793005 + 1442695040888963407

private def compareAll (actual : HashMap Nat Nat) (expected : Std.HashMap Nat Nat) : IO Unit := do
  ensure (actual.size == expected.size && actual.isValid) "differential size/invariant mismatch"
  for key in [:256] do
    ensure (actual.get? key == expected[key]?) s!"differential lookup mismatch for {key}"

private def testDifferential : IO Unit := do
  let mut actual : HashMap Nat Nat := {}
  let mut expected : Std.HashMap Nat Nat := {}
  let mut random : UInt64 := 0x9e3779b97f4a7c15
  for step in [:20000] do
    random := nextRandom random
    let key := ((random >>> 16).toNat % 256)
    if (random &&& 3) == 0 then
      actual := actual.erase key
      expected := expected.erase key
    else
      let value := random.toNat
      actual := actual.insert key value
      expected := expected.insert key value
    if step % 251 == 0 then compareAll actual expected
  compareAll actual expected

def main : IO Unit := do
  testGroups
  testNativeParity
  testBasic
  testCollisions
  testDifferential
  IO.println "All Hashi tests passed."
