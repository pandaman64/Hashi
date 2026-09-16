# Lean 4 での SwissTable HashMap 実装設計

対象ランタイムは Lean 4.34（`leanprover/lean4:v4.34.0`）。アルゴリズムの共通核は [SwissTable 設計](../swisstable/design.md)、符号化の既定は [hashbrown 寄り](../swisstable/comparison.md#11-新しい実装例-hashiへの示唆) とする。

目標は、**制御バイトを `ByteArray`、キー／値を `Array` に置き、ホットパスを `USize` と in-place 更新で回す**ことである。SIMD や非アラインロードは Lean に無いので、[ネイティブ計画](native-ops.md) の C 関数に切り出す。

## 1. なぜ Std.HashMap をそのまま使わないか

`Std.Data.DHashMap` は **separate chaining** である。バケットは `AssocList`（実質リスト）、負荷率 75%、バケット数は 2 の冪。検証向きで、SwissTable の「1 バイトメタデータ + グループ走査」ではない。

Hashi はキャッシュ効率と負荷率 7/8 を狙う別実装とする。証明は後段で、先に実行性能のレイアウトを固定する。

## 2. ランタイム上の表現

### 2.1 `ByteArray`（メタデータ）

Lean 上は `structure ByteArray where data : Array UInt8` だが、**実行時は packed scalar array** である。

```c
typedef struct {
  lean_object m_header;
  size_t m_size;
  size_t m_capacity;
  uint8_t m_data[];
} lean_sarray_object;
```

- `uget` / `uset` は `USize` 添え字で、要素は非ボックスの `uint8_t`
- RC が 1 なら `uset` は in-place
- `@& ByteArray` は借用（`b_lean_obj_arg`）。ルックアップで制御配列を inc/dec しない
- コンストラクタ経由の `data : Array UInt8` への変換は **線形時間**。ホットパスでは絶対に展開しない

制御バイトは必ずこの表現に置く。`Array UInt8` は 1 バイトが boxed オブジェクトになり、SwissTable の意味が消える。

### 2.2 `Array α` / `Array β`（キーと値）

```c
typedef struct {
  lean_object m_header;
  size_t m_size;
  size_t m_capacity;
  lean_object * m_data[];
} lean_array_object;
```

ジェネリックな `α` は **オブジェクトポインタの配列**になる。スロットを 1 配列に畳むより、キーと値を分ける方が Lean では有利である。

- find はキーだけ `uget` する。値のキャッシュラインを汚さない
- ヒット時だけ値の RC を増やす
- ユーザ指定どおり `keys : Array α`、`vals : Array β`

高速アクセスの約束:

| API | 用途 | RC |
| --- | --- | --- |
| `Array.uget` | 値を返す／保持する | 要素を `lean_inc` |
| `Array.ugetBorrowed`（unsafe） | その場の `BEq` だけ | inc しない |
| `Array.uset` | 挿入・削除 | exclusive なら in-place。旧要素を `lean_dec` |

`ugetBorrowed` で比較し、ヒットしたときだけ `uget`（または値配列側）で所有権を取る。

### 2.3 テーブルオブジェクト自体

```lean
structure RawTable (α β : Type) where
  ctrl       : ByteArray
  keys       : Array α
  vals       : Array β
  bucketMask : USize
  size       : USize
  growthLeft : USize
```

Lean のコンストラクタは先頭がオブジェクト、後ろがスカラーをパックできる。上の定義は実行時におおよそ次になる。

```
ctor {
  objs[0] = ctrl     // sarray*
  objs[1] = keys     // array*
  objs[2] = vals     // array*
  usize   bucketMask
  usize   size
  usize   growthLeft
}
```

`Nat` でサイズを持つと毎回ボックスされる。**マスク・要素数・growth はすべて `USize`。**

空スロットのキー／値は読まない（制御バイトが FULL のときだけ読む）。成長時は `Inhabited α` / `Inhabited β` の default で埋める。削除時は default を書き戻し、旧オブジェクトの RC を落とす。これをしていないと tombstone スロットに値が残り、リークする。

## 3. アルゴリズム上の固定値

hashbrown 側を採用する。理由は Lean のイテレータが「番兵バイト」を必要とせず、`size` フィールドで足りること、およびポータブルビット技が素直なこと。

| 項目 | Hashi の既定 |
| --- | --- |
| バケット数 | `2^m`（`bucketMask = n - 1`） |
| グループ幅 `W` | 第 1 段階 **8**（ポータブルと C が一致）。第 2 段階 16（SSE2） |
| EMPTY | `0xFF` |
| DELETED | `0x80` |
| FULL | `0x00–0x7F`（H2） |
| sentinel | なし |
| 制御バイト長 | `n + W`（末尾クローン `W` バイト） |
| 負荷率 | 7/8。`n ≤ 8` は EMPTY を 1 つ残す |
| クローン書き込み | `i` と `((i - W) & mask) + W` |

`W` を実行時に切り替えてはいけない。探査ストライドとクローン数が変わるため、**コンパイル時定数**にする。

三角探査:

```
pos₀    = H1(h) &&& bucketMask
stride ← stride + W
pos    ← (pos + stride) &&& bucketMask
```

H1 はハッシュの下位、H2 は上位 7 bit。Lean の `Hashable Nat` は avalanche が弱いので、Std と同じく挿入前にスクランブルする。

```
scramble(h) = let x := h ^^^ (h >>> 32)
              x ^^^ (x >>> 16)
H2 = (scramble(h) >>> 57).toUInt8   -- 上位 7 bit、FULL 形式
```

## 4. ホットパスの形

find は Lean に残す。キーの `BEq` / `Hashable` はユーザ定義で、C に渡せない。C に出すのは **制御バイトのグループ演算だけ**である。

```
find (m : @& RawTable α β) (k : α) : Option β :=
  if m.size == 0 then none
  else
    let h  := scramble (hash k)
    let h2 := H2 h
    let mut pos := H1 h &&& m.bucketMask
    let mut stride : USize := 0
    repeat
      let bits := Group.matchH2 m.ctrl pos h2          -- 予定: C
      -- bits の立っている bit i について
      --   idx := (pos + i) &&& m.bucketMask
      --   if keys.ugetBorrowed idx == k then
      --     return some (vals.uget idx)
      if Group.anyEmpty m.ctrl pos then return none    -- 予定: C
      stride := stride + W
      pos := (pos + stride) &&& m.bucketMask
```

挿入も同じループで「最初の EMPTY/DELETED」を記録する（hashbrown 流）。`matchEmptyOrDeleted` の最下位ビットが候補。小テーブル（`n < W`）ではクローン領域の偽 EMPTY を、先頭 Group の再スキャンで直す。

### 4.1 線形性（速さの前提）

`insert` / `erase` はテーブルを **所有**して受け取り、返す。

```lean
def get? (m : @& HashMap α β) (k : α) : Option β
def insert (m : HashMap α β) (k : α) (v : β) : HashMap α β
```

呼び出し側が `let m := m.insert k v` とすれば、外側 ctor も内側配列も RC=1 のまま `uset` がコピーしない。共有されていると配列が clone され、SwissTable の旨味が消える。デバッグには `ByteArray.markLinear` と `LEAN_ABORT_ON_NONLINEAR` を使う。

### 4.2 インデックスは `USize` のみ

`Nat` 添え字はスカラのボックス化と `lean_unbox` を招く。`ByteArray.get` / `Array.get` ではなく `uget` / `uset`。ループ変数も `USize`。

## 5. モジュール分割

```
Hashi.Swiss.Ctrl     制御タグ、H1/H2、容量・負荷率
Hashi.Swiss.Group    グループ走査（Lean ポータブル + @[extern]）
Hashi.Swiss.Raw      RawTable、find/insert/erase、再ハッシュ
Hashi.Swiss.HashMap  BEq / Hashable を束ねた公開 API
```

`Raw` はハッシュ値と等価関数を引数に取る低レベル層（hashbrown の `HashTable` に相当）。`HashMap` はそれを包む。

検証するときは `Ctrl` の符号化と `Raw` の探査不変条件（[設計 §11](../swisstable/design.md#11-アルゴリズム上の不変条件)）を先に定理化する。SIMD は「`matchH2` が返すビット集合が窓内の一致位置」という仕様に畳む。

## 6. 成長と確保

```
capacity_to_buckets(len):
  if len == 0: 0
  else if len < 4: 4
  else if len < 8: 8
  else nextPow2 (len * 8 / 7)

ctrl.size = buckets + W
keys.size = buckets
vals.size = buckets
growthLeft = bucket_mask_to_capacity(mask) - size
```

制御配列の初期化は `0xFF` の memset が必要で、Lean の `push` ループでは遅い。これは最初に C へ出す操作の一つ（`hashi_ctrl_alloc`）。フォールバックは `ByteArray.emptyWithCapacity` + `push`。

キー／値は `Array.mkArray buckets default`。

再ハッシュは新配列を確保して FULL スロットだけ insert する単純経路から始める。in-place rehash は後回し。

## 7. 空テーブル

`size = 0`、`bucketMask = 0`、`ctrl` / `keys` / `vals` は空。find はサイズ 0 で即 `none`。hashbrown の静的 EMPTY シングルトンは、Lean では RC と空配列の扱いが単純なこちらの方が良い。最初の insert で 4 または 8 バケットへ成長する。

## 8. 段階

1. **Lean ポータブル `W=8`** — `Hashi.Swiss.Group` 相当。インタプリタでも動く
2. **C の非アライン 8 バイトロード + SWAR + `ctz`** — 同じ ABI、同じ密なビットマスク
3. **`W=16` SSE2 / NEON** — `Group.width` とクローン数を切り替え、テーブルを作り直す前提
4. テーブルシード、検証付き WF、`try_reserve`

第 1 段階でも「制御は `ByteArray`、走査はグループ、キー比較は FULL だけ」を守れば、後から C を差しても `Raw` は書き換えない。
