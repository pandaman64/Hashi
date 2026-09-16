# Hashi

Lean 4 のライブラリ雛形。SwissTable ハッシュテーブルの調査資料を `docs/swisstable/` に置いている。

## SwissTable ドキュメント

Google SwissTable の設計と、Abseil / hashbrown 両実装の調査。

- [概要と一次資料](docs/swisstable/README.md)
- [設計（共通アルゴリズム）](docs/swisstable/design.md)
- [Abseil `raw_hash_set` 実装](docs/swisstable/abseil.md)
- [hashbrown `RawTable` 実装](docs/swisstable/hashbrown.md)
- [実装差の対照](docs/swisstable/comparison.md)

調査リビジョンは各文書の冒頭に記す。
