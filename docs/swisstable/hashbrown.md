# hashbrown SwissTable 実装

調査対象: rust-lang/hashbrown `8710205`（2026-09-06）

hashbrown は Abseil SwissTable の Rust 移植で、`no_std`（`alloc` 必須）かつ Rust 標準ライブラリの `HashMap` 実装の上流である。クレートとしての既定ハッシャは **foldhash**。`std` に取り込まれた版は `std::hash::RandomState`（SipHash 系）を既定にする。

中核モジュール:

| ファイル | 役割 |
| --- | --- |
| `src/raw.rs` | `RawTable` / `RawTableInner`。確保、探査、find/insert/erase、rehash |
| `src/control/tag.rs` | 制御タグ `Tag` |
| `src/control/bitmask.rs` | SIMD 結果のビットマスク反復 |
| `src/control/group/{sse2,neon,lsx,generic}.rs` | アーキテクチャ別 Group |
| `src/map.rs` / `src/set.rs` | `HashMap` / `HashSet` |
| `src/table.rs` | 明示ハッシュの低レベル `HashTable` |
| `src/hasher.rs` | `DefaultHashBuilder`（foldhash） |

公開 API は三層。

- `HashMap<K, V, S>` / `HashSet<T, S>` — std 互換。`Equivalent` による異種キー検索
- `HashTable<T>` — 呼び出し側が hash と eq を渡す。`IndexMap` など「キーが外にある」用途
- `RawTable<T>` — unsafe、クレート内

## 1. 制御タグ `Tag`

```
EMPTY   = 0b1111_1111   // 0xFF
DELETED = 0b1000_0000   // 0x80
FULL    = 0b0xxx_xxxx   // 上位 7 bit が H2
```

**sentinel は無い。** イテレーションは FULL の個数 (`items`) を数えるか、制御バイトを走査して FULL だけ yield する。

判定:

```
is_full(t)          t & 0x80 == 0
is_special(t)       t & 0x80 != 0     // EMPTY or DELETED
special_is_empty(t) t & 0x01 != 0     // 0xFF vs 0x80 を最下位 1 bit で区別
```

Abseil との対応は **入れ替わっている**:

| 意味 | Abseil | hashbrown |
| --- | --- | --- |
| EMPTY | `0x80` (-128) | `0xFF` |
| DELETED | `0xFE` (-2) | `0x80` |
| sentinel / 終端 | `0xFF` (-1) | なし（クローン余分バイトのみ） |

この符号化は「MSB=1 ⇔ 空き扱い（EMPTY/DELETED）」を保ったまま、NEON/汎用ビット技で EMPTY だけを「上位 2 bit が 1」として検出できるようにしている。

H2 の取り出し:

```
full(hash):
  top7 = hash >> (MIN_HASH_LEN * 8 - 7)
  Tag(top7 & 0x7f)
```

`MIN_HASH_LEN` は `min(sizeof(usize), 8)`。32bit で FxHash のように `usize` しか返さないハッシャでも、上位 7 bit がゼロにならないようにする。

`h1(hash) = hash as usize`（32bit では上位を捨てる）。

## 2. Group SIMD

`src/control/group/mod.rs` がコンパイル時に選ぶ。

| 実装 | 幅 `WIDTH` | 条件 |
| --- | --- | --- |
| SSE2 | 16 | `x86`/`x86_64` + `sse2`、非 miri |
| NEON | 8 | `aarch64` + `neon` + little-endian、非 miri |
| LSX | 16 | nightly + `loongarch64` + `lsx` |
| generic | 8 または 4 | フォールバック。ポインタ 64bit、および `aarch64` / `x86_64` / `wasm32` は 64bit ワード。それ以外の 32bit（例: `x86`）は 32bit ワード |

2019 年の解説では「NEON はレイテンシが高く ARM は常に generic」とされていたが、**現行 hashbrown は aarch64 little-endian で NEON を使う**。32bit ARM は generic のまま。AVX は実行時 dispatch が必要で、最初の数バケット以降マッチ確率が急減するので採用していない。

### SSE2

```
match_tag(tag)             pcmpeqb + pmovmskb → u16
match_empty()              match_tag(EMPTY)
match_empty_or_deleted()   pmovmskb(ctrl)     // MSB
match_full()               NOT of the above
convert_special...         (0 > ctrl) | 0x80  // EMPTY/DELETED→0xFF, FULL→0x80
```

Abseil の `psignb` による EMPTY 検出は使わない（EMPTY が -128 ではないため）。

### NEON

比較結果はレーンあたり `0x00`/`0xFF` のバイトマスクで、`vget_lane_u64` して 64bit に載せる。`BITMASK_STRIDE = 8`（抽象 1 bit が実 8 bit）。反復時は `BITMASK_ITER_MASK = 0x8080_..._80` で各バイト 1 bit に正規化する。

`match_empty_or_deleted` は符号付き `< 0`（`vcltz_s8`）。

### generic

グループ幅は `size_of::<GroupWord>()`。64bit ターゲットと `wasm32` は `u64`（幅 8）、その他の 32bit は `u32`（幅 4）。

ワード単位の bithacks。`match_tag` は Abseil portable と同じ手法で、**最下位 1 bit だけ違うタグに対する偽陽性**があり得る。EMPTY/DELETED では起きず、キー比較で補正する。

`match_empty`: 上位 2 bit が立っている（`x & (x<<1) & 0x80..80`）。

ビットマスクのエンディアン: 演算はネイティブエンディアンで行い、BitMask にする直前に `to_le()` する。空判定だけならバイトスワップを消せる余地がある。

32bit ARM の `trailing_zeros` は RBIT が古いコアに無いため、`swap_bytes + leading_zeros` に切り替える（各バイト 1 bit しか立たないことを利用）。

## 3. メモリレイアウト

確保は **1 本の割り当て**。スロットが前、制御バイトが後ろ。`ctrl` ポインタは制御配列の先頭（＝スロット配列の末尾の直後）を指す。

```
[ padding | T_{n-1} | ... | T_1 | T_0 | C_0 C_1 ... C_{n-1} | clones[0..WIDTH) ]
                                      ^
                                      ctrl ポインタ（data_end）
```

インデックス `i` の要素は `ctrl` から **後ろ向き** に取る。

```
bucket(i) = data_end.sub(i + 1)     // T_0 が index 0
```

ZST ではポインタ演算が潰れるので、`Bucket` は `(index + 1) as *mut T` としてインデックスを保持する。

制御バイト数:

```
num_ctrl_bytes = buckets + Group::WIDTH     // sentinel なし
buckets        = bucket_mask + 1            // 2 の冪
```

末尾 `WIDTH` バイトがクローン。最後の 1 バイトはアンアライン負荷で読まれないが、`set_ctrl` を分岐なしにするため書く。

`set_ctrl`:

```
index2 = ((index.wrapping_sub(WIDTH)) & bucket_mask) + WIDTH
ctrl[index]  = tag
ctrl[index2] = tag
```

`n < WIDTH` の例（2 バケット、Group=4）:

```
本物     | 間の EMPTY     | 右寄せクローン
[ A ][ B ][ EMPTY ][ EMPTY ][ A ][ B ]
```

クローンは右寄せ。途中の EMPTY が「偽の空き」になるため、insert は `fix_insert_index` で補正する。見つかった位置が FULL なら、先頭のアライン済み Group を再スキャンして本物の EMPTY/DELETED を取る。

アラインメント: 制御配列は `max(align_of::<T>(), Group::WIDTH)` に合わせる。スロット側のパディングで実現する。

## 4. 空シングルトン

`bucket_mask == 0` が空。`Group::static_empty()` という **Group アラインされた静的 `[EMPTY; WIDTH]`** を `ctrl` が指す。確保しない。

読み取りは常に安全（全部 EMPTY）。insert は resize を経て初めてヒープを取る。`clear` / drop だけがシングルトンと実配列を区別する。

## 5. 容量と負荷率

```
capacity_to_buckets(cap):
  if cap < 15:
    最小バケットは 4（2 は 1 要素しか置けないので飛ばす）
    要素サイズと Group::WIDTH に応じて最小 cap を底上げ
      (16, size≤1) → 14
      (16, size≤3) or (8, size≤1) → 7
      その他 → 3
    結果のバケットは 4 / 8 / 16
  else:
    buckets = next_power_of_two(cap * 8 / 7)

bucket_mask_to_capacity(mask):
  if mask < 8:  mask            // 1/2/4/8 バケットは 1 EMPTY を予約 → 実効 cap = mask
  else:         (mask+1)/8 * 7  // 87.5%
```

小テーブルで `ctrl_align` が大きい（SSE2 の 16）と、スロットが 1 バイトのときにパディングが支配的になる。その無駄を避けるため、極小容量をスキップして 16 バケットへ跳ばす。

`growth_left` は「あと何個 EMPTY を潰せるか」。tombstone を置いた削除では増やさない。

## 6. 探査

```
ProbeSeq { pos, stride }

probe_seq(hash):
  pos    = h1(hash) & bucket_mask
  stride = 0

move_next(bucket_mask):
  stride += Group::WIDTH
  pos     = (pos + stride) & bucket_mask
```

三角数探査そのものは Abseil と同一。マスクが `2^m - 1` ではなく「バケット数 2^m に対する `2^m - 1`」である点だけが容量表現の差。

## 7. find / insert / erase

### find

```
find_inner(hash, eq):
  tag = Tag::full(hash)
  probe = probe_seq(hash)
  loop:
    g = Group::load(ctrl[probe.pos])          // 非アライン
    for bit in g.match_tag(tag):
      i = (probe.pos + bit) & bucket_mask
      if eq(i): return Some(i)
    if g.match_empty().any_bit_set(): return None
    probe.move_next()
```

`eq` は `dyn FnMut(usize) -> bool`。動的ディスパッチでモノモルフィゼーションを減らし、LLVM が後で devirtualize する前提。

### insert

hashbrown は **find と挿入位置探索を同一ループで行う** (`find_or_find_insert_index_inner`)。

- H2 一致を eq で確認 → 既存
- 同時に最初の EMPTY/DELETED インデックスを記録
- EMPTY を含む Group に来たら、記録した位置を `fix_insert_index` して `Err(insert_index)`

既知未存在の挿入は `find_insert_index`（EMPTY/DELETED だけ探す）。

`record_item_insert_at`:

```
growth_left -= old_ctrl.special_is_empty() as usize   // EMPTY なら 1, DELETED なら 0
set_ctrl(index, new_full_tag)
items += 1
```

分岐なしで growth を更新する。

### erase

Abseil `WasNeverFull` と同じ距離判定。ただし EMPTY/DELETED の符号が違うので、leading/trailing zeros の意味はビットマスク側で揃えている。

```
index_before = (index - WIDTH) & bucket_mask
if empty_before.leading_zeros() + empty_after.trailing_zeros() >= WIDTH:
    set DELETED
else:
    growth_left += 1
    set EMPTY
items -= 1
```

`n < WIDTH` では `index_before == index` となり、DELETED は置かれない。

## 8. 再ハッシュ

`rehash_in_place`:

1. `convert_special_to_empty_and_full_to_deleted` を全 Group に適用（FULL→DELETED、特殊→EMPTY）
2. DELETED を走査し、ハッシュし直して `find_insert_index`
3. 新旧が同じ（非アライン）Group に属するなら動かさずタグだけ FULL に戻す
4. それ以外はスワップして、追い出された要素をループ継続（Robin Hood 的なキックアウトではない。単に連鎖移動）

ハッシュ関数が panic したら、残った DELETED を drop して EMPTY に戻す guard がある。Rust の panic safety への対応で、Abseil には無い。

通常の成長は新配列を確保して移す。`scopeguard` でハッシュ panic 時に新配列だけ解放する。

## 9. ハッシャと HashDoS

クレート既定は foldhash（高速、HashDoS 耐性は SipHash より弱い）。ドキュメントは耐性が必要なら `std::hash::RandomState` を明示するよう案内する。

`std` の `HashMap` は hashbrown を使うが、既定は RandomState のままなので、クレート直接利用より遅い代わりに耐性が高い。

ハッシュは `BuildHasher::hash_one` で 64bit。再ハッシュ時も毎回再計算する（H1 を保存しない）。

## 10. その他の Rust 固有点

- **Allocator**: `allocator-api2` / nightly `allocator_api`。確保失敗は panic または `TryReserveError`
- **Equivalent**: `Borrow` より広い異種キー。`equivalent` が true ならハッシュも一致しなければならない
- **ZST**: バケット数分の「論理スロット」は持つがデータ領域サイズ 0。制御バイトだけ確保
- **Clone**: 制御バイトを先にコピーし、要素 clone が成功してから `items` を立てる。途中 panic で未初期化スロットを drop しない
- **rayon / serde**: optional
- **raw-entry**: 非推奨 API を feature で隔離
- **inline-more**: ほとんどの関数に `#[inline]` を付け、実行速度とコンパイル時間をトレードオフ（既定 on）

`HashTable` は同一ハッシュの重複要素を禁止しない。その場合操作は `O(k)` になる。API が「自分の足を撃てる」低レベルである点が `HashMap` との差。
