# Hashi

Lean 4 向けの SwissTable 風ハッシュマップ実装。

- 制御バイトとキー／値を分離した SoA レイアウト
- 7-bit の H2 フィンガープリントと幅 8 のグループ走査
- 三角探査、末尾クローン、7/8 負荷率
- tombstone の再利用、容量拡張、再ハッシュ、`reserve`
- C のグループ演算・制御配列操作と、同じ意味を持つ Lean 実装

## 使用例

```lean
import Hashi

def capitals : Hashi.HashMap String String :=
  Hashi.HashMap.empty |>.insert "France" "Paris" |>.insert "Japan" "Tokyo"

#eval capitals.get? "Japan" -- some "Tokyo"
```

公開 API は `empty`、`size`、`capacity`、`get?`、`contains`、`insert`、
`erase`、`reserve`、`toList`、`fold`。更新操作はマップを所有して受け取り、
新しいマップを返す。`let m := m.insert k v` のように線形に使うと配列が
in-place 更新される。空スロットを初期化するため、更新操作にはキーと値の
`Inhabited` インスタンスが必要。

## ビルドと検証

```sh
lake build
lake build hashi_tests
lake exe hashi_tests
```

テストは Group の既知ベクトル、Lean と C の全窓同値検査、基本操作、
全キーが同じハッシュになるケース、20,000 操作の `Std.HashMap` との差分検査、
および内部不変条件の実行時検査を含む。

同一ランタイムの簡易ベンチマーク:

```sh
# 引数は要素数と lookup の反復回数
lake build hashi_bench
.lake/build/bin/hashi_bench 65536 20
```

CSV で `insert_grow`、`find_hit`、`find_miss` の ns/op を出力する。
コンパイル済み実行ファイルを使い、インタプリタの値は計測しない。

## SwissTable 調査

- [概要と一次資料](docs/swisstable/README.md)
- [設計（共通アルゴリズム）](docs/swisstable/design.md)
- [Abseil `raw_hash_set` 実装](docs/swisstable/abseil.md)
- [hashbrown `RawTable` 実装](docs/swisstable/hashbrown.md)
- [実装差の対照](docs/swisstable/comparison.md)

## Lean 4 実装資料

- [概要](docs/hashi/README.md)
- [レイアウトとホットパス](docs/hashi/lean-implementation.md)
- [不足操作と C ネイティブ計画](docs/hashi/native-ops.md)
- [ベンチマーク計画](docs/hashi/benchmarking.md)
