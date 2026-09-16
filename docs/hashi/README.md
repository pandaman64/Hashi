# Hashi 実装（Lean 4）

SwissTable 相当の HashMap を Lean 4 に載せる設計と実装資料。

実装は `Hashi/Swiss/`、C のグループ操作は `c/hashi_group.c` にある。
現在は資料の段階 1〜3（幅 8 のポータブル仕様、同じ ABI の C Group、
C による制御配列の確保とクローン更新）を実装している。SSE2/NEON の
幅 16 化と形式証明は今後の拡張であり、現在の C 実装はコンパイラが
最適化しやすい固定幅ループを使う。

1. [Lean 上のレイアウトとホットパス](lean-implementation.md)
2. [不足しているランタイム操作と C FFI 計画](native-ops.md)
3. [ベンチマーク計画](benchmarking.md)（Std.HashMap / Hashi / Abseil / hashbrown）

前提となるアルゴリズムと Abseil / hashbrown の差は [SwissTable 調査](../swisstable/README.md) を参照。
