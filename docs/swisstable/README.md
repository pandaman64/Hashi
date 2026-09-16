# SwissTable 調査ドキュメント

本ディレクトリは、Google の **SwissTable** ハッシュテーブル設計と、その二つの代表実装を一次ソースから調査した結果である。

| 実装 | 言語 | 調査時点のリビジョン |
| --- | --- | --- |
| [Abseil](https://github.com/abseil/abseil-cpp) `absl::container_internal::raw_hash_set` | C++ | `15ea57c` (2026-09-15) |
| [hashbrown](https://github.com/rust-lang/hashbrown) `RawTable` | Rust | `8710205` (2026-09-06) |

hashbrown は Abseil SwissTable の Rust 移植であり、Rust 1.36 以降の `std::collections::HashMap` の実装基盤でもある。ただし移植は機械的な 1:1 ではなく、制御バイト符号化・メモリレイアウト・容量表現・SIMD 選択などに意図的な差がある。

## 文書構成

1. [設計](design.md) — 両実装が共有するアルゴリズム（H1/H2、制御バイト、三角探査、SIMD グループ）
2. [Abseil 実装](abseil.md) — `raw_hash_set` を中心とした C++ 実装の詳細
3. [hashbrown 実装](hashbrown.md) — `RawTable` / `Group` を中心とした Rust 実装の詳細
4. [実装差](comparison.md) — 設計の共通点と、実装上の分岐点の対照

## 主な一次資料

- Abseil 設計ノート: [Swiss Tables Design Notes](https://abseil.io/about/design/swisstables)
- Abseil 発表: [Swiss Tables and absl::Hash](https://abseil.io/blog/20180927-swisstables)
- CppCon 2017: [Matt Kulukundis, *Designing a Fast, Efficient, Cache-friendly Hash Table*](https://www.youtube.com/watch?v=ncHmEUmJZf4)
- Aria Beingessner: [Swisstable, a Quick and Dirty Description](https://faultlore.com/blah/hashbrown-tldr/)（2019 年時点の hashbrown。現行実装とは NEON 採用などで差がある）
- Abseil 本体: `absl/container/internal/raw_hash_set.h`, `hashtable_control_bytes.h`, `raw_hash_set.cc`
- hashbrown 本体: `src/raw.rs`, `src/control/`
