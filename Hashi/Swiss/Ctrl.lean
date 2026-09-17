namespace Hashi.Swiss

namespace Ctrl

/-- Number of control bytes examined by one portable group operation. -/
def width : USize := 16

/-- Marks a bucket that has never held an element. -/
def empty : UInt8 := 0xff

/-- Marks a bucket whose element was erased. -/
def deleted : UInt8 := 0x80

@[inline] def isFull (c : UInt8) : Bool :=
  (c &&& 0x80) == 0

/-- The same inexpensive hash scrambling used by Lean's standard hash map. -/
@[inline] def scrambleHash (h : UInt64) : UInt64 :=
  let folded := h ^^^ (h >>> 32)
  folded ^^^ (folded >>> 16)

@[inline] def h1 (h : UInt64) (bucketMask : USize) : USize :=
  h.toUSize &&& bucketMask

@[inline] def h2 (h : UInt64) : UInt8 :=
  (h >>> 57).toUInt8

@[inline] def maxLoad (buckets : USize) : USize :=
  if buckets <= width then
    if buckets == 0 then 0 else buckets - 1
  else
    buckets - buckets / 8

/-- Allocate the control bytes, including the eight wraparound clones. -/
@[extern "hashi_ctrl_alloc"]
def alloc (buckets : USize) : ByteArray := Id.run do
  let total := buckets.toNat + width.toNat
  let mut ctrl := ByteArray.emptyWithCapacity total
  for _ in [:total] do
    ctrl := ctrl.push empty
  return ctrl

@[inline] def setAt (ctrl : ByteArray) (i : USize) (value : UInt8) : ByteArray :=
  if h : i.toNat < ctrl.size then ctrl.uset i value h else ctrl

/--
Update a real control byte and every corresponding byte in the cloned tail.
For the four-bucket table, each real byte occurs twice in that tail.
-/
@[extern "hashi_ctrl_set"]
def setWithClone (ctrl : ByteArray) (buckets i : USize) (value : UInt8) : ByteArray :=
  if buckets == 0 then ctrl
  else
    let ctrl := setAt ctrl i value
    let rec setClones (ctrl : ByteArray) (clone : USize) (fuel : Nat) : ByteArray :=
      match fuel with
      | 0 => ctrl
      | fuel + 1 =>
        if clone < buckets + width then
          setClones (setAt ctrl clone value) (clone + buckets) fuel
        else
          ctrl
    setClones ctrl (buckets + i) width.toNat

end Ctrl

end Hashi.Swiss
