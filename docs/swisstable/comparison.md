# Abseil と hashbrown の実装差

共通核は [設計](design.md) に書いた SwissTable アルゴリズムである。hashbrown の README も「Google SwissTable の Rust 移植」と明記する。差は **符号化・レイアウト・言語事情・公開後に積み上がった最適化** にある。機械的なポートではない。

以下、調査時点の HEAD（Abseil `15ea57c`、hashbrown `8710205`）に基づく。

## 1. 対照表

| 項目 | Abseil `raw_hash_set` | hashbrown `RawTable` |
| --- | --- | --- |
| 容量 | `2^m - 1` スロット。値自身がマスク | `2^m` バケット。`bucket_mask = n-1` |
| 最小成長単位 | 1, 3, 7, 15, … | 0 → 4 → 8 → 16 → …（2 バケットは飛ばす） |
| 負荷率 | 7/8。小容量は EMPTY を高々 1 | 7/8。`mask < 8` は EMPTY を 1 つ予約 |
| 制御バイト数 extra | `1 + (W-1)` = sentinel + clone | `W` clone のみ |
| EMPTY | `0x80` | `0xFF` |
| DELETED | `0xFE` | `0x80` |
| SENTINEL | `0xFF`（`ctrl[capacity]`） | なし |
| FULL | MSB=0 + H2 | 同左 |
| H2 | `size_t` の上位 7 bit | `u64` の上位 7 bit（32bit は `usize` 幅で調整） |
| シード | テーブルごとに 5 bit。Hash に混合 | テーブルシードなし（ハッシャ側の RandomState / foldhash 鍵） |
| メモリ順 | `[meta][ctrl\|sentinel\|clones][slots]` | `[pad][slots 逆順][ctrl\|clones]` |
| スロット番地 | `slots + i` | `ctrl.sub(i+1)` |
| 空テーブル | SOO または capacity 0。静的世代ポインタ等 | `bucket_mask==0` + 静的 `[EMPTY; W]` |
| インライン要素 | SOO、最大 1 要素 | なし（空のみ非確保） |
| SIMD x86 | SSE2、幅 16。SSSE3 `psignb` あり | SSE2、幅 16。`psignb` なし |
| SIMD ARM | aarch64 NEON 幅 8。EMPTY 系は portable | aarch64 NEON 幅 8。32bit ARM は generic |
| その他 SIMD | なし | nightly LoongArch LSX 幅 16 |
| portable Group | 常に 8 バイト | 64bit ワードが基本。32bit x86 などは 4 バイト。`wasm32` はポインタ 32bit でも 8 バイト |
| find+insert | 分離。insert は `find_first_non_full` | 同一ループで既存検出と空き記録 |
| イテレータ終端 | `kSentinel` | `items` カウント / FULL 走査 |
| 型消去 | 成長・消去・確保を `.cc` に集約 | `dyn Fn` でモノモルフィを抑制 |
| 観測 | hashtablez サンプリング | なし |
| デバッグ | sanitizer 世代、poison、低確率 rehash | debug_assert、panic guard |
| フラット/ノード | `flat_*` と `node_*` | 値直置きのみ。安定性が要るなら `Box` を値にする |
| 既定ハッシュ | `absl::Hash`（City/LowLevel + シード） | クレート: foldhash。std: SipHash RandomState |
| 異種キー | `is_transparent` | `Equivalent` / `Borrow` |
| アロケータ失敗 | 例外 or abort 方針（標準 new） | `TryReserveError` または abort |
| panic/例外安全 | 再入ガード、relocatable memcpy | `scopeguard` で確保済み新表を破棄 |
| 特殊スロット | blocked elements（未確保スロット） | 小テーブルの最小バケット底上げ |
| ZST | 特になし（C++ に ZST は稀） | インデックス埋め込み `Bucket` |

## 2. なぜ制御バイトが違うか

どちらも次の制約を満たす。

- FULL は MSB=0
- 特殊値は MSB=1 → `pmovmskb` / 符号ビットで一括検出
- EMPTY と DELETED はビット技で安く分離できる

Abseil は **SSE2 + イテレータ番兵** を最優先した。

- EMPTY = -128 → `psignb` が「EMPTY だけ非ゼロ」
- SENTINEL = -1 → ベクトル定数を `pcmpeqd xmm,xmm` で作る
- EMPTY/DELETED < SENTINEL → `pcmpgtb` で空き検出
- イテレータは `++ctrl` して番兵に当たるまで進む。C++ の forward iterator に自然

hashbrown は **番兵を捨て、EMPTY=0xFF / DELETED=0x80** にした。

- Rust のイテレータは `items` と `BitMask` で十分
- EMPTY の下位 bit が 1 なので `special_is_empty` が 1 命令
- generic/NEON の「上位 2 bit AND」で EMPTY だけ取れる
- tombstone 変換は `(high_bit ? 0xFF : 0x80)` で済む

どちらも正当だが、**ビットパターンを混同すると Match / MaskEmpty が壊れる**。移植や形式化では符号化をパラメータとして分けるべきである。

## 3. 容量 `2^m-1` 対 `2^m`

三角探査が全単射である条件は「**グループ数が 2 の冪**」である。

Abseil はスロット数を `2^m - 1` にし、

- `offset & capacity` がマスク
- インデックス `capacity` を sentinel に使える
- `NextCapacity = 2n+1` でグループ数は常に 2 倍

hashbrown はバケット数を `2^m` にし、

- 通例の power-of-two テーブルと同じ
- sentinel 用の「存在しないスロット」が要らない
- extra 制御バイトはちょうど `WIDTH`（クローンだけ）

クローン数もこれに連動する。Abseil は `W-1` clone + 1 sentinel = `W` extra。hashbrown は `W` clone。末尾の読み過ぎを防ぐという意味では同じ長さのパディングである。

## 4. レイアウトの向き

Abseil は読みやすい順（制御→スロット）で、スロットをアラインするために制御側にパディングを寄せることがある。サンプリング情報と世代を制御の **前** に置ける。

hashbrown は `ctrl` を境にスロットを負方向へ伸ばす。利点:

- `Bucket` が「基準ポインタ + インデックス」ではなく、要素への実ポインタに近い
- `index → pointer` が `base.sub(index+1)` で、データとメタデータのキャッシュラインが挿入ホットパスで近い（index 0 が ctrl の直前）
- 空シングルトンは制御バイトだけ指せばよく、TBAA/アライン問題を避けやすい

コストは「スロット 0 が確保ブロックの中央付近」になることと、デバッガでの見えにくさである。

## 5. SIMD 方針

共通: x86 は SSE2 幅 16 を最優先。AVX は使わない。

分岐:

- **AArch64 NEON**: 両者とも幅 8 で採用。Abseil は Match 以外を portable に戻してレジスタ転送を避ける。hashbrown は NEON を一貫して使う
- **ポータブル幅**: Abseil は常に 8。hashbrown は 32bit x86 などで 4 になり得る（テーブルサイズ計算が変わる）。`wasm32` は例外で 8
- **LoongArch LSX**: hashbrown nightly のみ
- **SSSE3 psignb**: Abseil のみ（EMPTY=-128 前提）

Group 幅が変わると、有効容量列・クローン数・「単一グループ」判定・小テーブルの tombstone 有無がすべて変わる。形式化では `W` をパラメータにする。

## 6. 空テーブルと SOO

hashbrown の空状態は「静的 EMPTY Group」。実装が単純で、find が分岐なしに空と分かる。

Abseil はさらに SOO で **1 要素をオブジェクト内**に置く。小さいマップの確保・TLB ミスを消す。代償として:

- `HeapOrSoo` union
- `is_soo` / `is_small` / `is_full_soo` の分岐
- SOO 専用イテレータ制御バイト
- サンプリング評価フラグのビット転用
- transfer が memcpy できない型向けの再入ガード

C++ ではマップオブジェクトがスタックに置かれやすく、SOO の旨味が大きい。Rust の `HashMap` はヒープ型として扱われることが多く、空非確保だけで十分な判断だったと考えられる。

## 7. ハッシュ混合

Abseil は **コンテナインスタンスごとのシード**を H1 に混ぜ、イテレーション順を表ごとに変える。`absl::Hash` はシード付きハッシュを直接受け、非 `absl::Hash` は xor する。

hashbrown の表自体はシードを持たない。ランダム性は `BuildHasher` に押し付ける。std の RandomState はプロセス（またはスレッド）寿命の鍵、foldhash も RandomState 相当を持つ。

形式的には「H1 は `mix(hash(key), table_seed)` の下位」と一般化できる。hashbrown は `table_seed = 0`、混合はハッシャ内部。

## 8. 挿入パス

Abseil の find は EMPTY で打ち切るだけ。空き位置は insert 時に `find_first_non_full` で取り直す。tombstone があるとき、find が見た「最初の EMPTY Group」より前の DELETED を再利用できる。

hashbrown は同一ループで「既存」と「最初の EMPTY/DELETED」を同時に集める。EMPTY に当たった時点の記録位置を使う。tombstone 再利用もこの一回で済む。

結果は同じ探査順・同じ「最初の空き」規則に従うはずだが、コード形状と命令キャッシュの特性は違う。hashbrown はさらに小テーブル用 `fix_insert_index` が明示的。Abseil は `SetCtrl` と cloned 領域、`is_single_group` で分散して扱う。

## 9. 成長アルゴリズム

どちらも概ね 2 倍にして載せ替える。差は最適化の深さ。

Abseil:

- 型消去された `GrowToNextCapacity`
- 未探査要素は新容量での位置が閉じ形式で求まる（`TryFindNewIndexWithoutProbing`）
- 探査が必要な要素だけ `ProbedItem` にパック
- relocatable 型はスロットサイズ別の共有 `memcpy`
- blocked elements でスロット確保量を削る

hashbrown:

- 新 `RawTableInner` を確保し、フルバケットを insert
- in-place rehash は tombstone 掃除用
- 小要素 + 大きな `ctrl_align` では最小バケットを底上げしてパディング率を下げる
- panic 時の guard

「載せ替えにハッシュ再計算が必要」は共通の制約。

## 10. API と安全性

| | Abseil | hashbrown |
| --- | --- | --- |
| イテレータ無効化 | insert で全無効。sanitizer 世代で検出 | Rust の借用規則でコンパイル時に排除 |
| 参照安定性 | flat は無し、node は有り | 無し（値を `Box` に入れる） |
| 未定義動作 | ダングリングイテレータ、要素破棄中の再入 | unsafe `RawTable` の契約。safe 層が包む |
| 確保失敗 | 例外 | `try_reserve` |
| 並列 | 外部同期 | rayon feature で並列イテレータ（テーブル自体は非 Sync 変更） |

hashbrown の safe API は「同一キーの重複を HashTable では止めない」など、低レベル逃げ道を残す。Abseil は `std::unordered_*` に寄せたセマンティクスと、透過ハッシュによる decomposable `emplace` が特徴。

## 11. 新しい実装（例: Hashi）への示唆

共通に固定してよいもの:

1. オープンアドレス + 制御バイト 1B + H2 指紋
2. 三角探査、グループ幅 `W`、容量はグループ数が 2 の冪
3. find は H2 一致のみキー比較、EMPTY で停止
4. 削除は「Group 幅の非 EMPTY 連続」のときだけ tombstone
5. 負荷率 7/8、常に EMPTY を 1 つ以上
6. 末尾クローンでラップなし SIMD ロード

先に決める分岐:

| 分岐 | 単純さ優先 | 性能/C++互換優先 |
| --- | --- | --- |
| 制御符号化 | hashbrown（sentinel なし、判定が単純） | Abseil（SSE 向け定数） |
| 容量 | `2^m` + mask（hashbrown） | `2^m-1` + sentinel（Abseil） |
| レイアウト | ctrl の後ろにスロット（Abseil 的で証明しやすい） | 逆向き（hashbrown） |
| SOO | 無し | 1 要素 SOO |
| テーブルシード | ハッシャ側 | コンテナ側 5 bit |
| Group 幅 | パラメータ `W`。8 の portable から始める | 16 の SIMD を後で足す |

Lean で不変条件を書くなら、[設計 §11](design.md#11-アルゴリズム上の不変条件) を共通コアにし、符号化と容量関数だけを実装パラメータにするのが扱いやすい。SIMD とクローンは「幅 `W` の窓が常に well-defined」という公理に畳める。
