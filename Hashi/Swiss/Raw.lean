import Hashi.Swiss.Group

namespace Hashi.Swiss

/--
The storage layer of the hash table. Control bytes are kept separate from keys
and values so unsuccessful lookups do not touch the values array.
-/
structure RawTable (α β : Type) where
  ctrl : ByteArray
  keys : Array α
  vals : Array β
  bucketMask : USize
  size : USize
  growthLeft : USize

namespace RawTable

def empty : RawTable α β where
  ctrl := {}
  keys := #[]
  vals := #[]
  bucketMask := 0
  size := 0
  growthLeft := 0

@[inline] def buckets (m : @& RawTable α β) : USize :=
  if m.ctrl.isEmpty then 0 else m.bucketMask + 1

def withBuckets [Inhabited α] [Inhabited β] (n : USize) : RawTable α β where
  ctrl := Ctrl.alloc n
  keys := Array.replicate n.toNat default
  vals := Array.replicate n.toNat default
  bucketMask := n - 1
  size := 0
  growthLeft := Ctrl.maxLoad n

/-- Avoid all slot work for the overwhelmingly common zero-candidate group. -/
private def matchingOffset? [BEq α] (m : @& RawTable α β) (pos : USize)
    (bits : UInt32) (key : α) : Option USize :=
  if bits == 0 then none
  else
    let rec go (offset : Nat) : Option USize :=
      if _h : offset < 8 then
        let bit := (1 : UInt32) <<< UInt32.ofNat offset
        if (bits &&& bit) != 0 then
          let idx := (pos + USize.ofNat offset) &&& m.bucketMask
          if hk : idx.toNat < m.keys.size then
            if m.keys.uget idx hk == key then some idx else go (offset + 1)
          else
            go (offset + 1)
        else
          go (offset + 1)
      else
        none
    go 0

private def matchingValueFrom? [BEq α] (m : @& RawTable α β) (pos : USize)
    (bits : UInt32) (key : α) (firstOffset : Nat) : Option β :=
  if bits == 0 then none
  else
    let rec go (offset : Nat) : Option β :=
      if _h : offset < 8 then
        let bit := (1 : UInt32) <<< UInt32.ofNat offset
        if (bits &&& bit) != 0 then
          let idx := (pos + USize.ofNat offset) &&& m.bucketMask
          if hk : idx.toNat < m.keys.size then
            if m.keys.uget idx hk == key then
              if hv : idx.toNat < m.vals.size then some (m.vals.uget idx hv) else none
            else
              go (offset + 1)
          else
            go (offset + 1)
        else
          go (offset + 1)
      else
        none
    go firstOffset

private structure InsertSearch where
  index : USize
  found : Bool

private def firstIndexInMask (m : @& RawTable α β) (pos : USize)
    (bits : UInt32) : Option USize :=
  if bits == 0 then none
  else
    let offset := USize.ofNat (Group.ctz bits).toNat
    some ((pos + offset) &&& m.bucketMask)

/--
Search for an existing key while remembering the first EMPTY/DELETED slot.
This is the hashbrown-style single-pass insertion probe.
-/
private def findForInsertWithHash? [BEq α] (m : @& RawTable α β) (key : α)
    (scrambled : UInt64) : Option InsertSearch :=
  let n := m.buckets
  if n == 0 then none
  else
    let groups := if n < Group.width then 1 else n.toNat / Group.width.toNat
    let tag := Ctrl.h2 scrambled
    let rec probe (fuel : Nat) (pos stride : USize)
        (firstVacant : Option USize) : Option InsertSearch :=
      match fuel with
      | 0 => firstVacant.map fun index => ⟨index, false⟩
      | fuel + 1 =>
        let group := Group.matchForInsert m.ctrl pos tag
        let candidates := group &&& 0xff
        match matchingOffset? m pos candidates key with
        | some index => some ⟨index, true⟩
        | none =>
          let available := (group >>> 16) &&& 0xff
          let firstVacant :=
            match firstVacant with
            | some index => some index
            | none => firstIndexInMask m pos available
          if (group &&& 0xff00) != 0 then
            firstVacant.map fun index => ⟨index, false⟩
          else
            let stride := stride + Group.width
            probe fuel ((pos + stride) &&& m.bucketMask) stride firstVacant
    probe groups (Ctrl.h1 scrambled m.bucketMask) 0 none

def findIndexWithHash? [BEq α] (m : @& RawTable α β) (key : α)
    (scrambled : UInt64) : Option USize :=
  let n := m.buckets
  if n == 0 then none
  else
    let groups := if n < Group.width then 1 else n.toNat / Group.width.toNat
    let tag := Ctrl.h2 scrambled
    let rec probe (fuel : Nat) (pos stride : USize) : Option USize :=
      match fuel with
      | 0 => none
      | fuel + 1 =>
        let group := Group.matchH2AndEmpty m.ctrl pos tag
        let bits := group &&& 0xff
        match matchingOffset? m pos bits key with
        | some idx => some idx
        | none =>
          if (group &&& 0xff00) != 0 then none
          else
            let stride := stride + Group.width
            probe fuel ((pos + stride) &&& m.bucketMask) stride
    probe groups (Ctrl.h1 scrambled m.bucketMask) 0

@[inline] def findIndex? [BEq α] [Hashable α] (m : @& RawTable α β)
    (key : α) : Option USize :=
  findIndexWithHash? m key (Ctrl.scrambleHash (hash key))

private def getWithHash? [BEq α] (m : @& RawTable α β) (key : α)
    (scrambled : UInt64) : Option β :=
  let n := m.buckets
  if n == 0 then none
  else
    let groups := if n < Group.width then 1 else n.toNat / Group.width.toNat
    let tag := Ctrl.h2 scrambled
    let rec probe (fuel : Nat) (pos stride : USize) : Option β :=
      match fuel with
      | 0 => none
      | fuel + 1 =>
        let group := Group.matchH2AndEmpty m.ctrl pos tag
        let bits := group &&& 0xff
        let hasHomeCandidate := (bits &&& 1) != 0
        let homeValue :=
          if hasHomeCandidate then
            let idx := pos &&& m.bucketMask
            if hk : idx.toNat < m.keys.size then
              if m.keys.uget idx hk == key then
                if hv : idx.toNat < m.vals.size then some (m.vals.uget idx hv) else none
              else
                none
            else
              none
          else
            none
        match homeValue with
        | some value => some value
        | none =>
          let remaining := bits &&& 0xfe
          let hasNextCandidate := (remaining &&& 2) != 0
          let nextValue :=
            if hasNextCandidate then
              let idx := (pos + 1) &&& m.bucketMask
              if hk : idx.toNat < m.keys.size then
                if m.keys.uget idx hk == key then
                  if hv : idx.toNat < m.vals.size then some (m.vals.uget idx hv) else none
                else
                  none
              else
                none
            else
              none
          match nextValue with
          | some value => some value
          | none =>
            match matchingValueFrom? m pos (remaining &&& 0xfc) key 2 with
            | some value => some value
            | none =>
              if (group &&& 0xff00) != 0 then none
              else
                let stride := stride + Group.width
                probe fuel ((pos + stride) &&& m.bucketMask) stride
    probe groups (Ctrl.h1 scrambled m.bucketMask) 0

private def findAvailableWithHash? (m : @& RawTable α β)
    (scrambled : UInt64) : Option USize :=
  let n := m.buckets
  if n == 0 then none
  else
    let groups := if n < Group.width then 1 else n.toNat / Group.width.toNat
    let rec probe (fuel : Nat) (pos stride : USize) : Option USize :=
      match fuel with
      | 0 => none
      | fuel + 1 =>
        let bits := Group.matchEmptyOrDeleted m.ctrl pos
        if bits != 0 then
          let offset := USize.ofNat (Group.ctz bits).toNat
          some ((pos + offset) &&& m.bucketMask)
        else
          let stride := stride + Group.width
          probe fuel ((pos + stride) &&& m.bucketMask) stride
    probe groups (Ctrl.h1 scrambled m.bucketMask) 0

private def writeNew (m : RawTable α β) (idx : USize) (tag : UInt8)
    (key : α) (value : β) : RawTable α β :=
  let previous :=
    if h : idx.toNat < m.ctrl.size then m.ctrl.uget idx h else Ctrl.deleted
  let keys :=
    if h : idx.toNat < m.keys.size then m.keys.uset idx key h else m.keys
  let vals :=
    if h : idx.toNat < m.vals.size then m.vals.uset idx value h else m.vals
  let n := m.buckets
  { m with
    ctrl := Ctrl.setWithClone m.ctrl n idx tag
    keys := keys
    vals := vals
    size := m.size + 1
    growthLeft := if previous == Ctrl.empty then m.growthLeft - 1 else m.growthLeft }

private def writeRehashed (m : RawTable α β) (idx : USize) (tag : UInt8)
    (key : α) (value : β) : RawTable α β :=
  let keys :=
    if h : idx.toNat < m.keys.size then m.keys.uset idx key h else m.keys
  let vals :=
    if h : idx.toNat < m.vals.size then m.vals.uset idx value h else m.vals
  let n := m.buckets
  { m with
    ctrl := Ctrl.setWithClone m.ctrl n idx tag
    keys := keys
    vals := vals
    size := m.size + 1
    growthLeft := m.growthLeft - 1 }

private def insertRehashedWithHash (m : RawTable α β) (key : α) (value : β)
    (scrambled : UInt64) (tag : UInt8) : RawTable α β :=
  let n := m.buckets
  if n == 0 then m
  else
    let groups := if n < Group.width then 1 else n.toNat / Group.width.toNat
    let rec probe (m : RawTable α β) (fuel : Nat) (pos stride : USize) : RawTable α β :=
      match fuel with
      | 0 => m
      | fuel + 1 =>
        let bits := Group.matchEmptyOrDeleted m.ctrl pos
        if bits != 0 then
          let offset := USize.ofNat (Group.ctz bits).toNat
          let idx := (pos + offset) &&& m.bucketMask
          writeRehashed m idx tag key value
        else
          let stride := stride + Group.width
          probe m fuel ((pos + stride) &&& m.bucketMask) stride
    probe m groups (Ctrl.h1 scrambled m.bucketMask) 0

private def insertNewWithHash (m : RawTable α β) (key : α) (value : β)
    (scrambled : UInt64) : RawTable α β :=
  match findAvailableWithHash? m scrambled with
  | some idx => writeNew m idx (Ctrl.h2 scrambled) key value
  | none => m

def rehash [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : RawTable α β) (newBuckets : USize) : RawTable α β := Id.run do
  let old := m
  let mut result := withBuckets (α := α) (β := β) newBuckets
  for i in [:old.buckets.toNat] do
    let control := old.ctrl.get! i
    if Ctrl.isFull control then
      let idx := USize.ofNat i
      if hk : idx.toNat < old.keys.size then
        if hv : idx.toNat < old.vals.size then
          let key := old.keys.uget idx hk
          let value := old.vals.uget idx hv
          let scrambled := Ctrl.scrambleHash (hash key)
          result := insertRehashedWithHash result key value scrambled control
  return result

private def prepareInsert [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : RawTable α β) : RawTable α β :=
  let n := m.buckets
  if n == 0 then
    withBuckets 4
  else if m.growthLeft == 0 then
    if m.size < Ctrl.maxLoad n then rehash m n else rehash m (n * 2)
  else
    m

def insert [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : RawTable α β) (key : α) (value : β) : RawTable α β :=
  let scrambled := Ctrl.scrambleHash (hash key)
  match findForInsertWithHash? m key scrambled with
  | some result =>
    if result.found then
      let vals :=
        if h : result.index.toNat < m.vals.size then
          m.vals.uset result.index value h
        else
          m.vals
      { m with vals := vals }
    else if m.growthLeft == 0 then
      let m := prepareInsert m
      insertNewWithHash m key value scrambled
    else
      writeNew m result.index (Ctrl.h2 scrambled) key value
  | none =>
    let m := prepareInsert m
    insertNewWithHash m key value scrambled

def get? [BEq α] [Hashable α] (m : @& RawTable α β) (key : α) : Option β :=
  getWithHash? m key (Ctrl.scrambleHash (hash key))

@[inline] def contains [BEq α] [Hashable α] (m : @& RawTable α β) (key : α) : Bool :=
  (findIndex? m key).isSome

def erase [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : RawTable α β) (key : α) : RawTable α β :=
  match findIndex? m key with
  | none => m
  | some idx =>
    let n := m.buckets
    let makeEmpty := n <= Group.width
    let ctrl := Ctrl.setWithClone m.ctrl n idx
      (if makeEmpty then Ctrl.empty else Ctrl.deleted)
    let keys :=
      if h : idx.toNat < m.keys.size then m.keys.uset idx default h else m.keys
    let vals :=
      if h : idx.toNat < m.vals.size then m.vals.uset idx default h else m.vals
    { m with
      ctrl := ctrl
      keys := keys
      vals := vals
      size := m.size - 1
      growthLeft := if makeEmpty then m.growthLeft + 1 else m.growthLeft }

def reserve [BEq α] [Hashable α] [Inhabited α] [Inhabited β]
    (m : RawTable α β) (capacity : Nat) : RawTable α β :=
  if capacity == 0 then m
  else
    let target := Nat.nextPowerOfTwo (capacity + capacity / 7 + 1) |>.max 4
    if target <= m.buckets.toNat then m else rehash m (USize.ofNat target)

def toList (m : @& RawTable α β) : List (α × β) := Id.run do
  let mut result := []
  for i in [:m.buckets.toNat] do
    if Ctrl.isFull (m.ctrl.get! i) then
      let idx := USize.ofNat i
      if hk : idx.toNat < m.keys.size then
        if hv : idx.toNat < m.vals.size then
          result := (m.keys.uget idx hk, m.vals.uget idx hv) :: result
  return result

/-- Executable check of the representation and probing invariants. -/
def isValid [BEq α] [Hashable α] (m : @& RawTable α β) : Bool := Id.run do
  let n := m.buckets
  if n == 0 then
    return m.size == 0 && m.ctrl.size == 0 && m.keys.size == 0 && m.vals.size == 0
  if n < 4 || (n &&& (n - 1)) != 0 then return false
  if m.ctrl.size != n.toNat + Group.width.toNat then return false
  if m.keys.size != n.toNat || m.vals.size != n.toNat then return false
  let mut full : USize := 0
  let mut occupied : USize := 0
  let mut hasEmpty := false
  let mut valid := true
  for i in [:n.toNat] do
    let c := m.ctrl.get! i
    if Ctrl.isFull c then
      full := full + 1
      occupied := occupied + 1
      let idx := USize.ofNat i
      if hk : idx.toNat < m.keys.size then
        let key := m.keys.uget idx hk
        if Ctrl.h2 (Ctrl.scrambleHash (hash key)) != c || !(m.findIndex? key).isSome then
          valid := false
      else
        valid := false
    else if c == Ctrl.deleted then
      occupied := occupied + 1
    else if c == Ctrl.empty then
      hasEmpty := true
    else
      valid := false
  for i in [:Group.width.toNat] do
    if m.ctrl.get! (n.toNat + i) != m.ctrl.get! (i % n.toNat) then
      valid := false
  return valid && hasEmpty && full == m.size &&
    occupied + m.growthLeft == Ctrl.maxLoad n

end RawTable

end Hashi.Swiss
