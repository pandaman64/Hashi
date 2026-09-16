# 不足しているランタイム操作と C 実装計画

Lean 4.34 の Init には SwissTable のホットパスに必要な演算が揃っていない。**キー比較とハッシュは Lean に残し、制御バイトに対するベクトル演算だけを C にする。**

C は別ライブラリとしてリンクする。Lean 側は `@[extern]` の本体をポータブル実装にしておき、インタプリタと証明は Lean 定義を使う。

## 1. Lean にあるもの / ないもの

| 操作 | Lean 4.34 | ホットパスでの扱い |
| --- | --- | --- |
| packed `uint8` 配列 | `ByteArray` / `lean_sarray` | 制御バイトに使う |
| オブジェクト配列 | `Array α` | キー／値 |
| in-place `uset`（RC=1） | あり | insert/erase |
| 借用 `@&` | あり | find のテーブル |
| `UInt64` の `&&&` `\|\|\|` `^^^` `<<<` `>>>` | あり | ポータブル SWAR、H1/H2 |
| `mixHash` | `@[extern]` 済み | ハッシュ混合 |
| `USize` 添え字の `uget` | あり | 必須 |
| 非アライン 8/16 バイトロード | **なし** | C `memcpy` / `loadu` |
| バイト列の memset / fill | **なし**（`push` のみ） | C `memset` |
| SIMD 比較・`pmovmskb` | **なし** | C SSE2 / NEON |
| ハードウェア `ctz` / `clz` | **なし**（`BitVec.ctz` は再帰） | C `__builtin_ctz` |
| prefetch | **なし** | C `__builtin_prefetch`（任意） |
| `Array.ugetBorrowed` | unsafe のみ | find の `BEq` |
| 未初期化ジェネリック配列 | **なし** | `Inhabited` default で埋める |

`Nat` のビット演算に落として `trailingZeros` 相当を書くと、整数のボックス化で遅くなる。ビットマスクは `UInt16` / `UInt32` のまま C の `ctz` に渡す。

## 2. ABI（第 1 段階、`W = 8`）

グループ演算は **密なビットマスク**を返す。bit `i` が立っていれば窓のオフセット `i` がヒット。Lean は `mask &&& (mask - 1)` で最下位ビットを削る。

引数 `ctrl` はすべて `@& ByteArray` → C では `b_lean_obj_arg`。`pos + 8 ≤ ctrl.size` は Lean 側の責任。C は `assert` するだけ。

| C シンボル | Lean | 意味 |
| --- | --- | --- |
| `hashi_group_match_h2` | `Group.matchH2 ctrl pos h2` | FULL かつ H2 一致 |
| `hashi_group_match_empty` | `Group.matchEmpty` | `0xFF` |
| `hashi_group_match_empty_or_deleted` | `Group.matchEmptyOrDeleted` | MSB=1 |
| `hashi_group_any_empty` | `Group.anyEmpty` | 停止判定。マスクより安い |
| `hashi_ctz32` | `Group.ctz` | `mask==0` なら 32 |
| `hashi_ctrl_alloc` | `Ctrl.alloc buckets` | `n+W` バイトを `0xFF` で確保 |
| `hashi_ctrl_set` | `Ctrl.setWithClone` | 本体とクローンを 2 書き |
| `hashi_ctrl_convert_rehash` | 再ハッシュ前処理 | EMPTY/DELETED→EMPTY、FULL→DELETED |

戻り値:

- マスク: `uint32_t`（下位 8 bit を使用。`W=16` に伸ばしても同じ関数名で 16 bit）
- `hashi_ctrl_alloc`: `lean_obj_res`（新しい `ByteArray`）
- `hashi_ctrl_set`: `lean_obj_res`（unique なら in-place の同じオブジェクト）

`hashi_ctrl_set` は Lean の `uset` を二回呼ぶより、C で `lean_byte_array_uset` 相当を一度 exclusive にして 2 バイト書く方が良い。

## 3. C 側の実装方針

### 3.1 ポータブル（必須、全アーキテクチャ）

hashbrown `generic.rs` と同じ SWAR。

```c
static inline uint64_t loadu64(const uint8_t *p) {
  uint64_t w;
  memcpy(&w, p, 8);   /* 非アライン許可 */
  return w;
}

static inline uint64_t splat(uint8_t t) {
  return (uint64_t)t * 0x0101010101010101ULL;
}

/* バイト一致 → 各バイトの MSB。その後 8 bit に圧縮 */
static uint32_t match_byte(uint64_t word, uint8_t t) {
  uint64_t x = word ^ splat(t);
  uint64_t m = (x - splat(0x01)) & ~x & splat(0x80);
  uint32_t bits = 0;
  for (int i = 0; i < 8; i++)
    if (m & (0x80ULL << (8 * i))) bits |= 1u << i;
  return bits;
}
```

圧縮ループはコンパイラが展開する。SSE2 があるときは圧縮の代わりに `pmovmskb` を使う。

EMPTY 検出（hashbrown）: 上位 2 bit が 1。

```c
uint64_t m = word & (word << 1) & splat(0x80);
```

EMPTY or DELETED: `word & splat(0x80)`。

`ctz`:

```c
uint32_t hashi_ctz32(uint32_t x) {
  return x == 0 ? 32u : (uint32_t)__builtin_ctz(x);
}
```

### 3.2 SSE2（x86_64、第 2 段階は `W=16`）

第 1 段階でも 8 バイト窓を XMM で処理できる。

```c
__m128i v = _mm_loadu_si128((const __m128i *)(p)); /* 16 バイト。末尾クローンで安全 */
__m128i eq = _mm_cmpeq_epi8(v, _mm_set1_epi8(h2));
uint32_t bits = (uint32_t)_mm_movemask_epi8(eq) & 0xFF; /* W=8 なら下位 8 */
```

`W=16` に上げるときは `& 0xFF` を外し、クローンを 16 バイト、探査ストライドを 16 にする。**既存テーブルは再ハッシュが必要。**

EMPTY or DELETED（hashbrown 符号化）は符号ビット: `_mm_movemask_epi8(v)`。

### 3.3 NEON（aarch64 little-endian、任意）

8 レーン `vld1_u8` + `vceq_u8`。戻りを密な 8 bit に圧縮して ABI を変えない。hashbrown は 64 bit のバイトマスク（stride=8）を返すが、Lean 側の反復を単純にするため **密なマスクに正規化してから返す。**

### 3.4 確保と fill

```c
LEAN_EXPORT lean_obj_res hashi_ctrl_alloc(size_t buckets) {
  size_t n = buckets + HASHi_WIDTH;     /* WIDTH=8 */
  lean_object *a = lean_alloc_sarray(/*elem_size*/1, n, n);
  memset(lean_sarray_cptr(a), 0xFF, n);
  return a;
}
```

`lean_mk_empty_byte_array` + 繰り返し `push` より一桁速い。容量ちょうどの sarray を作り、`m_size = n`。

## 4. Lean からの呼び出し規約

```lean
@[extern "hashi_group_match_h2"]
def matchH2 (ctrl : @& ByteArray) (pos : USize) (h2 : UInt8) : UInt32 :=
  Portable.matchH2 ctrl pos h2
```

- **コンパイル後**: リンカが C を解決する
- **インタプリタ / 証明**: 右辺のポータブル定義
- 両者は同じビット集合を返さなければならない。C のテストは Lean の `Portable` を oracle にする

`ByteArray` を C で読むときは `lean_sarray_cptr`。`ByteArray.mk` で `Array UInt8` に戻してはいけない。

書き込み系は owned `ByteArray` を受け、`lean_is_exclusive` でなければ copy（`lean_byte_array_uset` と同じ）。

## 5. Lake でのリンク

`lakefile.toml` では `extern_lib` が書けないので `lakefile.lean` に移す。

```lean
target hashiGroupO pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "hashi_group.o"
  let src ← inputTextFile (pkg.dir / "c" / "hashi_group.c")
  buildO oFile src #["-I", (← getLeanIncludeDir).toString] #["-fPIC", "-O2"]

extern_lib libhashi_group pkg := do
  let o ← hashiGroupO.fetch
  buildStaticLib (pkg.nativeLibDir / nameToStaticLib "hashi_group") #[o]
```

同じパッケージの `lean_exe` / `precompileModules` がこの静的ライブラリをリンクする。CI イメージは `cc` と Lean ヘッダを持つ。

SIMD を足すときは `buildO` の `traceArgs` に `-msse2` をアーキテクチャ条件で足す。Lake 側で `System.Platform.target` を見てもよいが、最初はコンパイラの組込み定義 `__SSE2__` に任せる。

## 6. やってはいけない切り出し

| 切り出し | 理由 |
| --- | --- |
| find 全体を C に置く | `BEq` / `Hashable` が Lean クロージャ。毎回のコールバックが SIMD より高い |
| キー配列を `ByteArray` にする | ジェネリック `α` はオブジェクト。非ボックス化できるのは `UInt8` / `Float` だけ |
| `Array (Option α)` をスロットにする | 追加の ctor ボックス。占有は制御バイトが持つ |
| C から `lean_apply` で等価関数 | FFI 往復がグループ走査より高い |

C の単位は「窓 1 つ分のマスク」または「制御配列の確保／2 点書き込み」まで。探査ループの制御は Lean に残す。

## 7. 検証との関係

ポータブル Lean 実装を仕様とみなす。

```
∀ ctrl pos h2,
  native.matchH2 ctrl pos h2 = Portable.matchH2 ctrl pos h2
```

これはコンパイル後の C に対する **trusted assumption** である。証明は `Portable` に対して行い、`@[extern]` は refinement とする。`W` や符号化を変えたら C と Lean を同じテストベクトルで照合する（`Main.lean` のスモークがその種）。

## 8. 実装順

1. `Portable.matchH2` / `matchEmpty` / `matchEmptyOrDeleted` / `ctz`
2. C で同じ関数を実装し、`@[extern]` で差し替え
3. `hashi_ctrl_alloc` / `hashi_ctrl_set`
4. SSE2 で `W=8` のまま `loadu`+`pmovmskb`（マスク ABI 不変）
5. `W=16` を別定数としてテーブル成長と同時に導入
6. prefetch はプロファイラで必要になってから
