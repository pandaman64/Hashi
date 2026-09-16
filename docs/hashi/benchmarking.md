# ベンチマーク計画

Hashi（SwissTable）を、次の四つと並べて測るための計画である。実装コードは含まない。

| 対象 | 言語 | アルゴリズム | スロット |
| --- | --- | --- | --- |
| `Std.Data.HashMap` | Lean 4.34 | separate chaining（`AssocList`、負荷 75%） | バケット配列 + リストノード |
| Hashi | Lean 4.34 | SwissTable（`ByteArray` 制御 + `Array` キー／値、負荷 7/8） | オープンアドレス |
| `absl::flat_hash_map` | C++ | SwissTable（Abseil `raw_hash_set`） | 値を配列に直置き |
| `hashbrown::HashMap` | Rust | SwissTable（`RawTable`） | 値を配列に直置き |

比較は二段に分ける。一段目が製品としての問い、二段目がアルゴリズムの天井である。

1. **同一ランタイム**: `Std.HashMap` 対 Hashi。どちらも Lean オブジェクトと RC を払う。ここで勝たなければ Hashi を採用する理由が薄い
2. **言語を跨いだ天井**: Hashi 対 Abseil / hashbrown。SwissTable 自体の速さの上限。差の大半はボックス化・RC・ハッシュ実装であり、テーブル探索だけではない

Hashi が未実装のあいだは、1 を欠いたまま 2 の Abseil / hashbrown と `Std.HashMap` だけを先に走らせ、ベースラインを取る。

詳細なアルゴリズム差は [SwissTable 比較](../swisstable/comparison.md)、Lean 側のレイアウトは [実装設計](lean-implementation.md) を参照する。

## 1. 公平さの制約

言語と表現が違うため、単一の「何倍速いか」は出さない。次を常にセットで報告する。

### 1.1 キーの表現

| キー | Lean | Abseil / hashbrown |
| --- | --- | --- |
| 64bit 整数 | `UInt64` は引数では非ボックスだが、`Array UInt64` は **ポインタ配列**（要素はボックス） | `int64_t` / `u64` をスロットに直置き |
| 任意精度整数 | `Nat`（小整数はタグ付き、大きいとヒープ） | 対応物なし。使わない |
| 文字列 | `String`（UTF-8 オブジェクト） | `std::string` / `String`（SSO の有無が違う） |

整数マップで Abseil が数倍速くても、Hashi が「ポインタを辿ってから 8 バイトを読む」コストを払っている可能性がある。同じギャップが `Std.HashMap` 対 Hashi にも出るが、**両者とも Lean のボックスを払う**ので、その差はテーブル構造の差として読める。

文字列はハッシュ計算が支配的になりやすい。テーブル差を見たいときは整数キーを主、文字列は副とする。

### 1.2 ハッシュ関数

既定ハッシュを混ぜて測ると、テーブルではなくハッシュが勝つ。

| 対象 | 既定 | 公平比較用 |
| --- | --- | --- |
| `Std.HashMap` | `Hashable` + `scrambleHash`（上位ビットを下位へ畳む） | 同じ `Hashable` インスタンス |
| Hashi | 設計上は同じ `Hashable` + scramble のうえ H2 を取る | Std と **同一**の `hash` |
| Abseil | `absl::Hash`（City / LowLevel + テーブルシード） | 整数は identity に近い専用ハッシャも別枠で測る |
| hashbrown クレート | foldhash | `std::hash::RandomState`（SipHash）も別枠 |
| `std::collections::HashMap` | SipHash | foldhash 版 hashbrown と混同しない |

**必須の対照**: Lean の `Std` と Hashi は同じ `Hashable` / `BEq`。整数キーでは `UInt64` の identity 相当（`hash n := n`）を明示する。

**参考の対照**: Abseil / hashbrown は「その言語の本番既定」と「安い identity ハッシュ」の二本。identity 同士なら探査とメモリがよく見える。既定同士ならユーザが実際に見る速さに近い。

### 1.3 成長と事前確保

insert ベンチは次の二本を分ける。

- **成長あり**: 空から `n` 個入れる。再ハッシュと確保を含む
- **`reserve(n)` 済み**: テーブル探査と書き込みだけ

Std は 75% で倍増、SwissTable は 7/8 で倍増なので、同じ `n` でもバケット数が違う。報告には最終 `size` と容量（またはバケット数）を添える。

### 1.4 Lean の線形性

Hashi も Std も、テーブルが共有されていると配列コピーが走る。ベンチの insert は

```
let mut m := {}
for k in keys do
  m := m.insert k v
```

のように **RC=1 を保つ**。共有したコピーへの insert は別ワークロード（persistent 更新）として測る。

### 1.5 コンパイラと最適化

| 実装 | ビルド |
| --- | --- |
| Lean | `lake build -R` 相当のリリース。インタプリタでは測らない |
| Abseil | `-O2` または `-O3`、NDEBUG、可能なら SSE2 |
| hashbrown | `--release`、既定 feature（foldhash + SSE2/NEON） |

CPU は同一マシン、ターボと周波数スケーリングを固定できるなら固定する。結果には CPU 名、OS、コンパイラ版、Lean 版を書く。

## 2. ワークロード

Abseil の `raw_hash_set_benchmark.cc` と、hashbrown / 典型的なハッシュマップベンチに合わせる。サイズ `n` は特に断らなければ `{16, 64, 256, 1024, 4096, 16384, 65536, 262144}`。キャッシュ境界（L1 / L2 / L3 / DRAM）を跨ぐように選ぶ。

キー列は固定シードの PRNG で事前生成し、四実装で **同じ数列**を使う。ヒットとミスは互いに素な集合にする。

### 2.1 コア（毎回出す）

| ID | 内容 | 見るもの |
| --- | --- | --- |
| `insert_grow` | 空から `n` 個 insert | 確保・再ハッシュ込みの挿入 |
| `insert_reserved` | `reserve(n)` のあと `n` 個 | 探査と書き込み |
| `find_hit` | `n` 個入りの表から存在するキー | 成功ルックアップ |
| `find_miss` | 同じ表から存在しないキー | EMPTY までの探査。H2 と負荷率が効く |
| `erase_present` | 入っているキーを消す | tombstone / リスト切り離し |
| `insert_after_erase` | `n` 個入れて `n/2` 消し、別キーを `n/2` 入れる | tombstone 再利用（SwissTable）対チェイン |

`find_*` は表を事前構築し、計測ループではルックアップだけする。

### 2.2 混合と反復

| ID | 内容 |
| --- | --- |
| `find_90_10` | ヒット 90% / ミス 10%。定常キャッシュ（Abseil `BM_CacheInSteadyState` に相当） |
| `erase_insert_churn` | 同じキーを消して入れ直す（Abseil `BM_EraseEmplace`） |
| `iterate` | 全要素を走査して値を読む |
| `copy` | 表の複製。Lean は構造共有、C++/Rust は深コピーになり得るので解釈に注意 |

### 2.3 キー型

優先度順。

1. `UInt64 → UInt64`（Lean）/ `int64_t` / `u64` — テーブル本体が見える
2. `String → UInt64` — 短い（≤15 バイト、SSO 圏）と長い（32–64 バイト）を分ける
3. （任意）大きい構造体や `Nat` — ボックスとハッシュの悪化を見るときだけ

Lean の `Nat` を Abseil の `int64_t` と並べない。

### 2.4 Hashi 内部の対比（実装後）

同一の Hashi API で次を切り替える。

- Group が Lean ポータブル `W=8` か、C の SWAR/SSE2 か
- `uget` か `ugetBorrowed` か（find の RC）

これは「アルゴリズム対 Std」ではなく「ネイティブ化の効果」である。表を分けて出す。

## 3. 指標

各セルは **1 操作あたりのナノ秒**（中央値と MAD、または Google Benchmark の `cpu_time`）を基本とする。加えて:

| 指標 | 用途 |
| --- | --- |
| ns/op | 主指標 |
| 最終バケット数 / `size` | 負荷率の差 |
| ヒープバイト（可能なら） | Lean は `EStateM` では取れないことが多い。C++/Rust はアロケータカウンタや `/proc` |
| 探査長（SwissTable のみ） | Hashi / Abseil / hashbrown の内部カウンタ。Std はチェイン長 |
| スループット（ops/s） | 大きい `n` の find |

成功ルックアップと失敗ルックアップは絶対に平均しない。

## 4. ハーネス

四つのランタイムを一つのプロセスにリンクしない。測定は言語ごとの実行ファイル、集計は共通の表にする。

```
bench/
  cases.json          # n, シード, キー生成、ワークロード ID
  lean/               # Std と Hashi。IO.monoNs または専用ループ
  cpp/                # absl::flat_hash_map, google/benchmark
  rust/               # hashbrown, criterion または iai ではなく wall-clock の単純ループでも可
  report/             # 生成した CSV / Markdown
```

`cases.json` が単一の真とする。キー列は「シードと生成器が同じなら同じ列」になるよう、言語間で一致する PRNG（例: SplitMix64）を各自実装する。

### 4.1 Lean

- コンパイル済み `lean_exe`
- 内側ループは `USize`、`for in [:n]` の `Nat` ボックスを避ける
- 結果をコンパイラに消されないよう、アキュムレータを `IO.println` するか `opaque` な sink に渡す
- ウォームアップのあと、同じワークロードを十分繰り返して中央値を取る
- `Std.Data.HashMap` は `insert` / `get?` / `erase`。Hashi も同じ名前に揃える

インタプリタ（`lean --run`）の数字は表に載せない。

### 4.2 C++

Abseil 既存の `raw_hash_set_benchmark.cc` を参考にするが、比較用には `absl::flat_hash_map<int64_t, int64_t>` と `flat_hash_map<std::string, int64_t>` に限定した薄いドライバで足りる。`benchmark::DoNotOptimize` を使う。

### 4.3 Rust

`hashbrown::HashMap` を直接使う（`std::collections::HashMap` は SipHash なので別行）。`criterion` でも、Lean と同じ「事前生成キー + 固定反復」の手動ループでもよい。後者の方が言語間のプロトコルを揃えやすい。

## 5. 結果の読み方

期待されるおおまかな順序（整数キー、find_hit、大きい `n`）:

```
Abseil ≈ hashbrown(foldhash)  <<  Hashi(C Group)  ≤  Hashi(Lean Group)  <  Std.HashMap
```

ここから外れたときは、まず次を疑う。

- Hashi が Std より遅い: 線形性の破綻（毎回 clone）、`Nat` 添え字、制御バイトを `Array UInt8` にしている、find で不要な `lean_inc`
- Hashi が Abseil に近い: 測定がハッシュか確保だけを見ている（キーが重すぎる、`n` が小さすぎる）
- hashbrown が Abseil より明らかに遅い: SipHash の `std` HashMap を測っていないか
- 小さい `n` で Abseil だけ速い: SOO（1 要素インライン）

`find_miss` では SwissTable の H2 が効き、Std のチェイン走査との差が開きやすい。逆に `iterate` では Std も連続したバケット配列を見るため差が縮みうる。Hashi はキー配列と値配列が分かれているので、値まで読む iterate は不利になり得る。

## 6. 報告テンプレ

各実行で次をヘッダに置く。

- 日付、CPU、周波数ガバナ、Lean / clang / rustc の版
- コミット、最適化フラグ、Hashi の Group 実装（portable / C）
- ハッシュ方針（Lean 共通 `Hashable`、Abseil 既定 or identity、hashbrown foldhash or SipHash）

表はワークロード × `n` × 実装。単位は ns/op。脚注にバケット数と「成長あり／reserve 済み」を書く。

`Std` 対 Hashi の列を先に出し、Abseil / hashbrown は「天井」として右に置く。四者を同じスケールの棒グラフにすると、Lean の二本が潰れて見えるので、グラフも二段にする。

## 7. 実装順

1. `cases.json` と SplitMix64 のキー生成を四言語で一致させる
2. `Std.HashMap` の Lean ハーネス（これだけでベースラインになる）
3. Abseil / hashbrown の同じ cases
4. Hashi 実装後、同じ Lean ハーネスに差し込む
5. Hashi の portable Group 対 C Group
