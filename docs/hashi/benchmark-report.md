# Hashi 比較ベンチマーク報告

## 条件

- 実施日: 2026-09-16、コード: `168cde9`
- CPU: Intel Xeon、4 vCPU、x86_64
- Lean 4.34.0、Clang 18.1.3、release ビルド、C Group 幅 8
- `UInt64 → UInt64`、262,144 要素、lookup 100 反復
- 各条件 5 回実行の中央値。find は構築済みテーブル、insert は空からの成長込み

実行コマンド:

```sh
lake build hashi_bench
.lake/build/bin/hashi_bench 262144 100
```

## 最適化後の比較

単位は ns/op。小さい方が速い。

| workload | Hashi | `Std.HashMap` | Hashi / Std |
| --- | ---: | ---: | ---: |
| `insert_grow` | 235.882 | 141.534 | 1.667× |
| `find_hit` | 39.896 | 27.995 | 1.425× |
| `find_miss` | **14.988** | 16.761 | **0.894×** |

Hashi の `find_miss` は `Std.HashMap` より 10.6% 高速になった。insert と
hit は引き続き Std が速い。

## H2 ゼロマスク高速化

`matchingOffset?` が候補ゼロでも 8 オフセットを走査していたため、ゼロマスクを
即時終了するよう変更した。

| workload | 変更前 | 変更後 | 変化 |
| --- | ---: | ---: | ---: |
| `insert_grow` | 286.262 | 252.201 | -11.9% |
| `find_hit` | 39.815 | 39.518 | -0.7% |
| `find_miss` | 30.556 | 22.701 | **-25.7%** |

gprof では miss 時の候補走査再帰が 109,333,979 回から 3,443,481 回へ
96.9% 減少した。ヒット性能を維持しながら、ミス検索の対 Std 比を
1.764×から 1.355×へ縮めた。

## H2/EMPTY Group 走査の統合

次のプロファイルでは、miss ごとに同じ制御バイトを読む
`hashi_group_match_h2` と `hashi_group_any_empty` が上位だった。C 側で一度だけ
8バイトを読み、H2 と EMPTY の両マスクを一つの `UInt32` に詰めて返すようにした。

| workload | 統合前 | 統合後 | 変化 |
| --- | ---: | ---: | ---: |
| `insert_grow` | 252.201 | 235.882 | -6.5% |
| `find_hit` | 39.518 | 39.896 | +1.0% |
| `find_miss` | 22.701 | **14.988** | **-34.0%** |

hit の 1.0% 差は実行間のばらつきの範囲。最初の実装から通算すると
`find_miss` は 30.556 ns から 14.988 ns へ 50.9% 改善した。

## 解釈と次の候補

- miss の次の上位コストは統合後の `hashi_group_match_h2_and_empty` と
  `findIndexWithHash?`。次は SIMD 化または Group 幅 16 の検討対象
- hit は `RawTable.get?` と候補キー取得が中心
- insert は RC 解放と再ハッシュが支配的。`reserve` 済み測定との分離が必要

VM の周波数は固定しておらず、単一サイズ・整数キーのみの結果である。
Abseil/hashbrown、erase、文字列、メモリ使用量はこの報告には含まない。
