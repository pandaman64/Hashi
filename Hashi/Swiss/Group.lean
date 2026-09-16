import Hashi.Swiss.Ctrl

namespace Hashi.Swiss

-- Portable eight-byte SwissTable control-group operations.
namespace Group

def width : USize := Ctrl.width

namespace Portable

@[inline] def getCtrl (ctrl : @& ByteArray) (i : USize) : UInt8 :=
  if h : i.toNat < ctrl.size then ctrl.uget i h else Ctrl.empty

def matchLoop (ctrl : @& ByteArray) (pos : USize)
    (pred : UInt8 → Bool) : UInt32 :=
  let rec go (offset : Nat) (bits : UInt32) : UInt32 :=
    if _h : offset < 8 then
      let c := getCtrl ctrl (pos + USize.ofNat offset)
      let bit := (1 : UInt32) <<< UInt32.ofNat offset
      go (offset + 1) (if pred c then bits ||| bit else bits)
    else
      bits
  go 0 0

def matchH2 (ctrl : @& ByteArray) (pos : USize) (tag : UInt8) : UInt32 :=
  matchLoop ctrl pos fun c => Ctrl.isFull c && c == tag

def matchEmpty (ctrl : @& ByteArray) (pos : USize) : UInt32 :=
  matchLoop ctrl pos fun c => c == Ctrl.empty

def matchEmptyOrDeleted (ctrl : @& ByteArray) (pos : USize) : UInt32 :=
  matchLoop ctrl pos fun c => !Ctrl.isFull c

def matchH2AndEmpty (ctrl : @& ByteArray) (pos : USize) (tag : UInt8) : UInt32 :=
  matchH2 ctrl pos tag ||| (matchEmpty ctrl pos <<< 8)

def anyEmpty (ctrl : @& ByteArray) (pos : USize) : Bool :=
  matchEmpty ctrl pos != 0

/-- Position of the least significant set bit, or 32 for a zero mask. -/
def ctz (bits : UInt32) : UInt32 :=
  let rec go (n : Nat) (x : UInt32) : UInt32 :=
    if _h : n < 32 then
      if (x &&& 1) != 0 then UInt32.ofNat n
      else go (n + 1) (x >>> 1)
    else
      32
  go 0 bits

end Portable

@[extern "hashi_group_match_h2", inline]
def matchH2 (ctrl : @& ByteArray) (pos : USize) (tag : UInt8) : UInt32 :=
  Portable.matchH2 ctrl pos tag

@[extern "hashi_group_match_empty", inline]
def matchEmpty (ctrl : @& ByteArray) (pos : USize) : UInt32 :=
  Portable.matchEmpty ctrl pos

@[extern "hashi_group_match_empty_or_deleted", inline]
def matchEmptyOrDeleted (ctrl : @& ByteArray) (pos : USize) : UInt32 :=
  Portable.matchEmptyOrDeleted ctrl pos

/--
Return H2 matches in bits 0–7 and EMPTY matches in bits 8–15.
The native implementation computes both while loading the group only once.
-/
@[extern "hashi_group_match_h2_and_empty", inline]
def matchH2AndEmpty (ctrl : @& ByteArray) (pos : USize) (tag : UInt8) : UInt32 :=
  Portable.matchH2AndEmpty ctrl pos tag

@[extern "hashi_group_any_empty", inline]
def anyEmpty (ctrl : @& ByteArray) (pos : USize) : Bool :=
  Portable.anyEmpty ctrl pos

@[extern "hashi_ctz32"]
def ctz (bits : UInt32) : UInt32 :=
  Portable.ctz bits

end Group

end Hashi.Swiss
