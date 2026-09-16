# Abseil SwissTable 実装

調査対象: abseil-cpp `15ea57c`（2026-09-15）

中核は `absl/container/internal/raw_hash_set.h` と、そこから切り出された

- `hashtable_control_bytes.h` — `ctrl_t` / `Group` / `BitMask`
- `raw_hash_set.cc` — 型消去された find/insert/resize/erase
- `raw_hash_set_resize_impl.h` — 成長時の probed element 符号化
- `hash_policy_traits.h` / `container_memory.h` — スロット政策とハッシュ混合
- `hashtablez_sampler.h` — 実行時サンプリング

公開型は政策クラスを差し替えた薄いラッパである。

| 公開型 | スロット | ポインタ安定性 |
| --- | --- | --- |
| `absl::flat_hash_set` / `flat_hash_map` | 値を配列に直置き | なし（rehash で移動） |
| `absl::node_hash_set` / `node_hash_map` | ノードへのポインタ | あり（ノードアドレスは不変） |

既定の選択は flat。ポインタ安定性が必要なら `flat_hash_map<K, unique_ptr<V>>` が推奨されることが多い。

## 1. 制御バイト `ctrl_t`

`enum class ctrl_t : int8_t`。ビットパターンは **SSE 向けにチューニング**されている。

| 状態 | 値 | ビット | 選定理由 |
| --- | --- | --- | --- |
| `kEmpty` | -128 | `1000_0000` | 符号付き 8bit の最小値。SSSE3 `psignb` で EMPTY 検出、飽和減算で変換 |
| `kDeleted` | -2 | `1111_1110` | `ConvertSpecialToEmptyAndFullToDeleted` が単純になる |
| `kSentinel` | -1 | `1111_1111` | `pcmpeqd xmm, xmm` でレジスタに作れる。イテレータ終端 |
| FULL | `0..127` | `0hhh_hhhh` | MSB=0。H2 そのもの |
| `kMarkedForSlowTransfer` | -3 | （内部） | resize の低速経路用 |

静的アサートが要求する性質:

- 特殊値はすべて MSB=1 → `movemask` で「非 FULL」が取れる
- `kEmpty < kSentinel` かつ `kDeleted < kSentinel` → `cmpgt` で EMPTY/DELETED を一括検出
- `kEmpty` と `kDeleted` は sentinel が持たない「落ちているビット」を共有 → スカラーの `MaskEmptyOrDeleted` が速い

```
IsEmpty(c)          c == kEmpty
IsFull(c)           (int8_t)c >= 0
IsDeleted(c)        c == kDeleted
IsEmptyOrDeleted(c) c < kSentinel     // -128 と -2 だけ
```

hashbrown と異なり **sentinel がある**。イテレータは制御バイトを順に進め、`kSentinel` で止まる。容量 `capacity` の位置が番兵であり、スロット配列の長さでもある。

## 2. Group SIMD

`hashtable_control_bytes.h` でアーキテクチャ別に切り替える。

| 実装 | 幅 `kWidth` | 条件 |
| --- | --- | --- |
| `GroupSse2Impl` | 16 | `ABSL_INTERNAL_HAVE_SSE2` |
| `GroupAArch64Impl` | 8 | ARM NEON かつ little-endian |
| `GroupPortableImpl` | 8 | それ以外。64bit ワードのビット技 |

x86 では `Group = GroupSse2Impl`。AArch64 では Match には NEON を使うが、EMPTY/DELETED のカウント系は **GPR との転送レイテンシを避けるためポータブル実装** (`GroupFullEmptyOrDeleted = GroupPortableImpl`) を使う。

### SSE2 の要点

```
Match(h2)              pcmpeqb + pmovmskb
MaskEmpty()            SSSE3 なら psignb（kEmpty=-128 専用）、なければ pcmpeqb
MaskFull()             pmovmskb(ctrl) XOR 0xFFFF   // MSB=0 が FULL
MaskEmptyOrDeleted()   pcmpgtb(kSentinel, ctrl)
ConvertSpecialToEmptyAndFullToDeleted
                       (ctrl & 0x80) を飽和減算 2 → EMPTY(-128) / DELETED(-2)
```

`_mm_movemask_epi8` の結果は 16 ビットだが、`BitMask` は `uint32_t` に入れる。16bit レジスタには `blsr` が無く、32bit の方が `operator++`（最下位ビット削除）のコードが良いため。

GCC の `-funsigned-char` では `_mm_cmpgt_epi8` が壊れる既知バグがあり、その場合は比較を手で直す。

### ポータブル Match

Stanford bithacks の「ワード内のバイト一致」:

```
x = ctrl XOR broadcast(h2)
mask = (x - 0x0101..01) AND NOT x AND 0x8080..80
```

偽陽性があり得るが、(1) 真の一致があるときだけ (2) EMPTY/DELETED/SENTINEL では起きない (3) 後段のキー比較で落とす、とコメントされている。

## 3. 容量と負荷率

有効容量は **非ゼロの `2^m - 1`**。

```
IsValidCapacity(n) = ((n+1) & n) == 0 && n > 0
NextCapacity(n)    = 2n + 1          // 1, 3, 7, 15, 31, ...
NormalizeCapacity  = 次の 2^m-1
```

`capacity` 自身がビットマスクになる。探査オフセットは `offset & capacity`。

負荷率:

```
kMaxCapacityForLoadFactorOne = Group::kWidth * 4 - 1

CapacityToGrowth(cap):
  if cap <= kMaxCapacityForLoadFactorOne:
    return cap - (cap >= Group::kWidth - 1)   // 小テーブルは EMPTY を高々 1
  return cap - cap/8                           // 7/8
```

`is_single_group(cap)` は `cap <= Group::kWidth`。このとき探査は不要で、イテレーション順も任意でよい。

`kMaxSmallCapacity = 1`。容量 0 または 1 は「ハッシュ不要」の small モード（SOO またはインライン 1 要素）になる。

## 4. バッキング配列レイアウト

```
BackingArray {
  HashtablezInfoHandle infoz_;          // サンプリング時のみ
  uint64_t growth_left_overflow;        // 大容量時のみ
  ctrl_t   ctrl[capacity];
  ctrl_t   sentinel;                    // 常に kSentinel
  ctrl_t   clones[Group::kWidth - 1];   // ctrl[0 .. W-2] の複製
  GenerationType generation;            // sanitizer ビルド時
  slot_type slots[capacity - blocked];  // アラインメント調整あり
}
```

制御バイト数:

```
NumClonedBytes()              = Group::kWidth - 1
NumControlBytes(capacity)     = 0                          // small
                              | capacity + 1 + NumClonedBytes()
```

extra は sentinel 1 + clone `W-1` でちょうど 1 グループ分。イテレータは `ctrl[capacity]` の sentinel で停止する。

`SetCtrl` は本物と複製を同時に書く。

```
ctrl[i] = h
ctrl[((i - (W-1)) & capacity) + (W-1)] = h
```

単一グループ表では `ctrl[i + capacity + 1] = h` に単純化できる。

スロットは制御バイトの **後ろ**。ハッシュセットオブジェクト自体は `CommonFields`（インラインの容量・サイズ・シードと、ヒープポインタまたは SOO スロットの union）を持つ。

### Small Object Optimization (SOO)

スロットが `HeapOrSoo`（ヒープ側ポインタと同等のサイズ・アライン）に収まるとき、**最大 1 要素**をオブジェクト内に置く。

```
SooCapacity() = 1
SooEnabled()  = policy.soo_enabled
             && sizeof(slot)  <= sizeof(HeapOrSoo)
             && alignof(slot) <= alignof(HeapOrSoo)
```

複数 SOO を避ける理由は、削除時のイテレータ安定性と、小テーブルのイテレーション順のランダム化が複雑になるため。SOO イテレータ用に静的な `{FULL, SENTINEL}` 制御バイト `kSooControl[2]` がある。

## 5. 探査列

```
p(i) = W * i(i+1)/2 + hash   (mod capacity+1)
```

実装:

```
probe_seq(capacity, hash):
  offset_ = hash & capacity
  index_  = 0

next():
  index_  += W
  offset_ += index_
  offset_ &= capacity
```

`H1(hash) = hash`（下位ビットをそのまま使う）、`H2(hash) = hash >> (sizeof(size_t)*8 - 7)`。

テスト `probe_seq<16>(capacity=127, hash=0)` のオフセット列:

```
0, 16, 48, 96, 32, 112, 80, 64
```

これは `16 * i(i+1)/2 mod 128` に一致する。

## 6. find / insert / erase

### find

small なら要素は高々 1 個で、等価比較するだけ。それ以外は `find_large`:

```
hash = hash_of(key)          // テーブルシードを混合済み
seq  = probe(capacity, hash)
h2   = H2(hash)
loop:
  prefetch(slots + seq.offset)
  g = Group(ctrl + seq.offset)
  for i in g.Match(h2):
    off = seq.offset(i)      // (offset_ + i) & capacity
    if equal(key, slots[off]): return iterator
  if g.MaskEmpty(): return end
  seq.next()
```

テンプレートの `find` はインラインに残し、成長・再ハッシュ・消去メタ更新など太い経路は `raw_hash_set.cc` の **型消去関数** に出す。`PolicyFunctions` は `hash_slot` / `transfer_n` / `alloc` などの関数ポインタ束である。同じスロットサイズの relocatable 型は `memcpy` 版 `TransferNRelocatable<Size>` を共有し、バイナリサイズを抑える。

### insert

`find_or_prepare_insert` → 未存在なら `PrepareInsertLarge`。

- 削除なしで `growth_left > 0` なら、find が見つけた「EMPTY を含む Group」に置く
- tombstone がある場合は `find_first_non_full` で EMPTY **または** DELETED を取り直す（DELETED を優先再利用）
- 空きが無ければ grow または in-place rehash

`find_first_non_full` は最初のバイトがすでに EMPTY/DELETED なら探査 0、否则 `MaskEmptyOrDeleted` が立つまで `seq.next()`。

### erase

`EraseMetaOnlyLarge`:

```
if WasNeverFull(index):
    SetCtrl(index, kEmpty)
    growth_left を EMPTY 側に戻す
else:
    SetCtrl(index, kDeleted)
```

`WasNeverFull` は hashbrown と同じ「前後 Group の EMPTY 距離」判定。単一グループ表では常に true（tombstone 不要）。

空スロットは ASan/MSan で poison する。

## 7. ハッシュと per-table seed

各テーブルは **5 bit のシード**を `size` と同じ `uint64_t` にパックして持つ。目的は **イテレーション順の非決定性**（小テーブルでハッシュしない場合にも効く）。

```
HashElement:
  absl::Hash なら HashWithSeed(hash, key, seed)
  それ以外なら hash(key) XOR seed
```

非既定ハッシャではシードの下位が 0 になり得るので、xor 前にシフトを戻す (`kSeedShift`)。サンプリングされたテーブルは固定シード `kSampledSeed` を使い、hashtablez がビットの偏りを観測できるようにする。

`absl::Hash` 本体は CityHash / LowLevelHash 系の MixingHashState で、ユーザ型は `AbslHashValue` で拡張する。Swiss table の既定ハッシャである。

## 8. 成長と resize

通常は `NextCapacity` で約 2 倍（`2n+1`）。高速経路 `GrowToNextCapacity` は:

1. 旧テーブルで **未探査**（最初の Group に収まる）要素を、新テーブルの対応位置へ直接 transfer
2. 探査が必要だった要素は `ProbedItem{4,8,16}Bytes` に `(h2, source_offset, h1)` をパックして後回し
3. 後回し分だけ `find_first_non_full` する

これにより「ほとんどの要素は再探査しない」。単一グループからの成長ではスロットをまとめて `transfer_n` できる。

ランダムに低確率 rehash する経路もある（sanitizer 世代カウンタ用。`RehashProbabilityConstant() = 16`）。

## 9. Blocked elements

比較的新しい最適化。制御配列の長さは `capacity = 2^m-1` のまま、**スロット本体を一部確保しない**。

```
BlockedInfo(log2_period, tail_blocked)
  周期 2^log2_period ごとに 1 スロットを block
  さらに末尾 tail_blocked 個を block
```

block した制御バイトには `kSentinel` を書き、対応スロットは割り当てない。

```
alloc_size = slot_offset + (capacity - blocked_element_count) * slot_size
```

大規模表では blocked 数を最大 5 に制限し、平均探査が O(1) から外れないようにする。hashbrown には無い。

## 10. イテレータと世代

```
++it:
  ++ctrl; ++slot
  skip_empty_or_deleted()
  if *ctrl == kSentinel: slot = nullptr   // end
```

end は `slot_ == nullptr`。デフォルト構築イテレータは別の番兵ポインタで end と区別する。

ASan / HWAsan / MSan かつ非 `NDEBUG_SANITIZER` では `ABSL_SWISSTABLE_ENABLE_GENERATIONS` が有効になり、バッキング配列とイテレータに世代番号を付ける。insert で世代を進め、間接参照時に「無効化されたイテレータ」を検出する。reserve 後の最初の insert や低確率 rehash も、参照無効化バグを顕在化させるため。

## 11. Hashtablez

グローバルサンプラが一定割合のテーブルを観測する。記録内容はサイズ、容量、探査長、SOO か否か、キー/値サイズなど。サンプリングされた表はカスタムアロケータに加えてグローバル `operator new` を使う可能性があり、特殊環境では無効化する。

## 12. 政策 (Policy) と分解挿入

`hash_policy_traits` がスロットの construct / destroy / transfer / キー抽出を抽象化する。`Policy::apply` による **decomposable insert** で、`emplace` はキーが既に存在するとき値を構築しない（`std::unordered_map` が先にノード確保してしまう問題の回避）。`init_type` と `value_type` を分け、initializer からのムーブを許可する。

`try_emplace` は不成功時に引数をムーブしない。

## 13. 空状態と CommonFields

`HashtableInlineData` に容量・サイズ・シード・infoz ビット・blocked 数・growth_left 下限をビットフィールド的に詰める。既定は容量を log2 で 6 bit に圧縮するモード（`kCapacityByLog`）。SOO 時はシードの最下位ビットを「サンプリング評価済み」フラグに転用する。
