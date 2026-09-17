# Hashi 比較ベンチマーク報告

## 条件

- 実施日: 2026-09-17、コード: `4e8499e`
- CPU: Intel Xeon、4 vCPU、x86_64
- Lean 4.34.0、Clang 18.1.3、release ビルド、C Group 幅 8
- `UInt64 → UInt64`、262,144 要素、lookup 100 反復
- 各条件 5 回実行の中央値。find は構築済みテーブル
- insert は完成マップをタイマー停止後まで保持し、破棄を計測外にした

実行コマンド:

```sh
lake build hashi_bench
.lake/build/bin/hashi_bench 262144 100
```

## 最適化後の比較

単位は ns/op。小さい方が速い。

| workload | Hashi | `Std.HashMap` | Hashi / Std |
| --- | ---: | ---: | ---: |
| `insert_grow` | 108.492 | 78.845 | 1.376× |
| `insert_reserved` | 68.794 | 35.318 | 1.948× |
| `find_hit` | **26.617** | 28.228 | **0.943×** |
| `find_miss` | **10.289** | 16.437 | **0.626×** |

Hashiの`find_hit`は`Std.HashMap`より5.7%、`find_miss`は37.4%高速。
insertは引き続きStdが速い。insertはallocatorの影響による実行間変動が大きいため、
絶対値に加えて各runのHashi/Std比も評価する。

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

## SSE2 Group 比較

統合Group関数の自動ベクトル化は8回の個別ロードと多数のunpack命令を生成して
いた。x86_64 では64-bitロード、`pcmpeqb`、`pmovmskb`を使うSSE2実装へ変更し、
他アーキテクチャにはポータブル実装を残した。

| workload | SSE2 前 | SSE2 後 | 変化 |
| --- | ---: | ---: | ---: |
| `insert_grow` | 235.882 | 249.544 | +5.8% |
| `find_hit` | 39.896 | 38.151 | -4.4% |
| `find_miss` | 14.988 | **11.563** | **-22.9%** |

insert は実行間のばらつきが大きく、改善は確認できない。gprof では統合Group関数の
self time が 0.52秒から0.21秒へ59.6%減り、計装全体も1.43秒から1.05秒へ減った。
最初の実装から通算した `find_miss` の改善は62.2%。

## 挿入探査の単一pass化

新規insertは従来、既存キー検索の後に空きスロットを別の探査で検索していた。
H2、EMPTY、EMPTY/DELETEDを一回のSSE2ロードで取得し、既存判定と最初の空きを
同じ探査ループで処理するhashbrown型の経路へ変更した。

| workload | 単一pass前 | 単一pass後 | 変化 |
| --- | ---: | ---: | ---: |
| `insert_grow` | 249.544 | **226.534** | **-9.2%** |
| `find_hit` | 38.151 | 38.746 | +1.6% |
| `find_miss` | 11.563 | 11.263 | -2.6% |

lookup差はコード配置と実行間のばらつきの範囲。最初の実装から通算すると
`insert_grow` は286.262 nsから226.534 nsへ20.9%改善した。

ここまでのinsert値は完成マップの破棄を含む旧harnessの値である。同じ条件内の
相対比較には使えるが、現在のinsert絶対値とは直接比較しない。

## insert harnessの分離

完成マップをサイズだけに射影すると、キー・値配列の再帰的なRC破棄まで計測区間に
入っていた。マップ自体をタイマーから返して破棄を計測外へ移し、事前確保も分離した。

| workload | Hashi ns/op | `Std.HashMap` ns/op |
| --- | ---: | ---: |
| 旧`insert_grow`（破棄込み） | 226.534 | 145.346 |
| `insert_grow`（破棄なし） | **169.298** | **84.212** |
| `insert_reserved`（reserveも計測外） | **86.420** | **42.325** |

Hashiの破棄除外で見かけのinsert時間は25.3%減った。これは実装高速化ではなく、
測定対象の修正である。

## 比較profile後の最適化

再ハッシュ先が新規テーブルであることを利用し、汎用の`Option`空き探索を経由せず
EMPTY slotへ直接配置する専用経路を追加した。さらにEMPTY/DELETEDの8-byte走査を
SSE2の`pmovmskb`へ変更した。

- growのgprof sampled time: 1.20秒 → 0.86秒 → 0.81秒
- 汎用`findAvailableWithHash?`: 22,938,300回 → 900回
- 通常ベンチの対Std比（各run比の中央値）: 2.010× → 約1.50×

lookupはindexを`Option USize`で返してからvalue配列を再度読む経路を廃止し、
候補キー一致時にvalueを直接返すようにした。

- hitのgprof sampled time: 2.87秒 → 2.11秒（-26.5%）
- hitの通常ベンチ対Std比: 1.316× → 1.069×
- missの通常ベンチ対Std比: 0.674× → 0.610×

probeからEMPTY情報を`writeNew`へ運びcontrol byte再読込を省く案も測定したが、
reserved profileは1.15秒から1.13秒の改善に留まり、growが悪化したため撤回した。

key/valueの二配列を`Array (α × β)`へ統合する案も試した。`writeNew`単体は
0.65秒から0.54秒へ17%短縮したが、pair objectの割当と間接参照が増え、
reserved profile全体は1.15秒から1.21秒へ悪化した。通常ベンチ中央値も
growが118.714 nsから179.291 ns、hitが31.060 nsから45.689 nsへ悪化した。
再ハッシュの各移動でもpairを再確保するため、この配置は撤回した。

## hit候補offset 0のfast path

直接valueを返す変更後も、候補確認はoffset 0から始めるboxed `Nat`ループだった。
生成Cでは各hitで`Nat`比較、`UInt32` shift、`USize`変換を行っていた。最初の
control bitが立っている場合はhome bucketを直接確認し、残りだけ従来ループへ渡す。

- `matchingValue?`再帰呼び出し: 104,886,800回 → 25,993,600回（-75.2%）
- hit gprof sampled time: 2.11秒 → 2.06秒、同条件のStdは2.88秒
- hit通常ベンチ: 31.060 ns/op → 26.617 ns/op（-14.3%）
- hit対Std比: 1.059× → 0.943×

## 解釈と次の候補

- hit/missは候補キー・valueの同時取得が中心。Group幅16化も検討対象
- grow insertは専用再配置後も配列確保と`writeRehashed`が主要コスト
- reserved insertは引き続き3配列を更新する`writeNew`が最大

VM の周波数は固定しておらず、単一サイズ・整数キーのみの結果である。
Abseil/hashbrown、erase、文字列、メモリ使用量はこの報告には含まない。
