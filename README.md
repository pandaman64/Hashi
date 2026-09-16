# Hashi

Lean 4 のライブラリ雛形。SwissTable の調査と、Lean 4 実装の設計資料を `docs/` に置いている。

## SwissTable 調査

- [概要と一次資料](docs/swisstable/README.md)
- [設計（共通アルゴリズム）](docs/swisstable/design.md)
- [Abseil `raw_hash_set` 実装](docs/swisstable/abseil.md)
- [hashbrown `RawTable` 実装](docs/swisstable/hashbrown.md)
- [実装差の対照](docs/swisstable/comparison.md)

## Lean 4 実装設計

コードはまだない。設計のみ。

- [概要](docs/hashi/README.md)
- [レイアウトとホットパス](docs/hashi/lean-implementation.md)
- [不足操作と C ネイティブ計画](docs/hashi/native-ops.md)
