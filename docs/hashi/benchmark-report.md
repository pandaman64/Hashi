# Hashi 比較ベンチマーク報告

## 条件

- 実施日: 2026-09-16、コード: `7fd9709`
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
| `insert_grow` | 252.201 | 142.505 | 1.770× |
| `find_hit` | 39.518 | 27.902 | 1.416× |
| `find_miss` | 22.701 | 16.755 | 1.355× |

Hashi は現状すべての項目で `Std.HashMap` より遅い。差が最も小さいのは
SwissTable の制御バイト走査が効く `find_miss`。

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

## 解釈と次の候補

- miss の次の上位コストは `hashi_group_match_h2`、`findIndexWithHash?`、
  `hashi_group_any_empty`
- hit は `RawTable.get?` と候補キー取得が中心
- insert は RC 解放と再ハッシュが支配的。`reserve` 済み測定との分離が必要

VM の周波数は固定しておらず、単一サイズ・整数キーのみの結果である。
Abseil/hashbrown、erase、文字列、メモリ使用量はこの報告には含まない。
