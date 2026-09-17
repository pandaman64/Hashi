import Hashi.Swiss.Raw

namespace Hashi

/--
A SwissTable-style hash map with separate control, key, and value arrays.

Mutating operations consume and return the map. Keeping that use linear lets
Lean update all three arrays in place.
-/
structure HashMap (α β : Type) where
  private raw : Swiss.RawTable α β

namespace HashMap

def empty : HashMap α β :=
  ⟨Swiss.RawTable.empty⟩

instance : EmptyCollection (HashMap α β) where
  emptyCollection := empty

instance : Inhabited (HashMap α β) where
  default := empty

@[inline] def size (m : @& HashMap α β) : Nat :=
  m.raw.size.toNat

@[inline] def capacity (m : @& HashMap α β) : Nat :=
  m.raw.buckets.toNat

@[inline] def isEmpty (m : @& HashMap α β) : Bool :=
  m.raw.size == 0

@[inline] def get? [BEq α] [Hashable α] (m : @& HashMap α β) (key : α) : Option β :=
  m.raw.get? key

@[inline] def contains [BEq α] [Hashable α] (m : @& HashMap α β) (key : α) : Bool :=
  m.raw.contains key

@[inline] def insert [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : HashMap α β) (key : α) (value : β) : HashMap α β :=
  ⟨m.raw.insert key value⟩

@[inline] def erase [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : HashMap α β) (key : α) : HashMap α β :=
  ⟨m.raw.erase key⟩

@[inline] def reserve [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : HashMap α β) (capacity : Nat) : HashMap α β :=
  ⟨m.raw.reserve capacity⟩

def toList (m : @& HashMap α β) : List (α × β) :=
  m.raw.toList

def fold (m : @& HashMap α β) (init : γ) (f : γ → α → β → γ) : γ :=
  m.toList.foldl (fun acc entry => f acc entry.1 entry.2) init

/-- Run the internal representation checker; useful in tests and debug builds. -/
def isValid [BEq α] [Hashable α] (m : @& HashMap α β) : Bool :=
  m.raw.isValid

end HashMap

end Hashi
