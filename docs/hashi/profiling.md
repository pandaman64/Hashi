# Hashi のプロファイリング

`hashi_profile` は Hashi だけを対象に、挿入・ヒット検索・ミス検索を別々に
実行するドライバである。通常のベンチマークに計装の影響を残さないよう、
`lakefile.profile.lean` は `-pg` を付けた release ビルドを
`.lake/build-profile` に出力する。

## 実行

Linux で `gprof`（通常は `binutils` に含まれる）を用意し、リポジトリの
ルートで次を実行する。

```sh
./scripts/profile.sh find-hit
./scripts/profile.sh find-miss 262144 400
./scripts/profile.sh insert-grow 262144 50
```

引数は workload、要素数、反復数。結果は
`.lake/profiles/<workload>/report.txt` に保存され、端末には flat profile の
先頭を表示する。サンプルが少ない場合は反復数を増やす。`gprof` の時間サンプル
は通常 0.01 秒単位なので、少なくとも数秒実行する。

手動実行もできる。

```sh
lake -f lakefile.profile.lean build hashi_profile
cd .lake/profiles
../build-profile/bin/hashi_profile find-hit 262144 400
gprof -b ../build-profile/bin/hashi_profile gmon.out > report.txt
```

## 読み方

Lean は型ごとに特殊化した長いネイティブシンボルを生成する。今回のホットパスで
注目する対応は次のとおり。

| シンボルに含まれる文字列 | 処理 |
| --- | --- |
| `RawTable_get` | 公開 lookup から値を返す部分 |
| `findIndexWithHash` / `probe` | 三角探査と EMPTY 停止判定 |
| `matchingOffset` | H2 候補に対するキー配列アクセスと `BEq` |
| `hashi_group_match_h2` | C の幅 8 制御バイト比較 |
| `hashi_group_any_empty` | C の EMPTY 検出 |
| `RawTable_insert` / `writeNew` | 挿入と配列更新 |
| `RawTable_rehash` | 成長時の再ハッシュ |
| `hashi_ctrl_set` | 本体・クローン制御バイトの更新 |

flat profile の self time は関数自身、call graph の children time は呼び出し先を
含む。検索では `findIndexWithHash`、`matchingOffset`、Group C 関数をまとめて
見る。挿入では `rehash` を分け、定常挿入と成長コストを混同しない。

`gprof` は CPU 時間と呼び出し数を把握するための仕組みで、キャッシュミスや
分岐ミスなどのハードウェアイベントは測らない。`perf` が利用可能な Linux
環境では通常ビルドに対して次も併用できる。

```sh
lake build hashi_profile
perf record -g -- .lake/build/bin/hashi_profile find-miss 262144 400
perf report
```

コンテナでは `perf_event_paranoid` や capability により拒否されることがある。
その場合でも `gprof` 経路はカーネルの perf 権限を必要としない。

## 初回ベースラインで見えた箇所

Lean 4.34、262,144 要素での初回計測では、次が上位だった。割合は gprof の
self-time サンプルであり、絶対性能や通常ビルドの ns/op としては扱わない。

- `find-hit`: `RawTable.get?` 29.8%、`matchingOffset?` 26.9%、
  `hashi_group_match_h2` 9.8%。`Option` の生成・破棄を含む lookup の Lean 側と
  H2 候補処理が中心
- `find-miss`: `matchingOffset?` 37.5%、`hashi_group_match_h2` 14.4%、
  `hashi_group_any_empty` 12.0%
- `insert-grow`: RC 解放系が約 45%、`writeNew` 15.0%、再ハッシュ走査 6.5%。
  5,242,880 回の利用者 insert に対して `writeNew` は 14,417,840 回呼ばれ、
  成長時の再挿入コストが明確

最も具体的な検索側の問題は、`matchingOffset?` が H2 マスクがゼロでも 8
オフセットを再帰走査する点だった。挿入側では `reserve` 済みプロファイルを
追加して再ハッシュと定常書き込みを分離し、その後に RC と配列更新を調べる
余地が残っている。

## ゼロ H2 マスク高速化の結果

`matchingOffset?` にゼロマスクの即時終了を追加した。262,144 要素、
lookup 100 反復で最適化前後をそれぞれ 5 回測り、中央値を比較した。

| workload | 最適化前 ns/op | 最適化後 ns/op | 変化 |
| --- | ---: | ---: | ---: |
| `insert_grow` | 286.262 | 252.201 | -11.9% |
| `find_hit` | 39.815 | 39.518 | -0.7% |
| `find_miss` | 30.556 | 22.701 | **-25.7%** |

別時間帯の測定差を補うため同じプロセスの `Std.HashMap` との比も見ると、
`find_miss` は 1.764 倍から 1.355 倍へ改善（比率で -23.2%）。`find_hit` は
1.385 倍から 1.416 倍で、測定誤差を超える改善は確認できない。挿入時間は
ばらつきが大きく、比率では 1.921 倍から 1.770 倍（-7.9%）だった。

gprof の `find-miss` では `matchingOffset?` の再帰本体の呼び出しが
109,333,979 回から 3,443,481 回へ 96.9% 減った。全体の計装 CPU 時間も
2.08 秒から 1.17 秒へ減少したが、これは gprof 計装下の値なので通常ビルドの
ns/op の代わりにはしない。

途中で二つの案も検証した。

- 非ゼロマスクを `ctz` で辿る案は `find_miss` を改善した一方、
  `find_hit` の中央値が 39.815 ns から 43.392 ns へ悪化したため、ゼロ時だけ
  即時終了し、非ゼロ時は従来の低オーバーヘッド走査を使う形にした
- `Array.ugetBorrowed` によるキー比較は小規模テストを通ったが、262,144
  要素ベンチで毎回 segmentation fault になった。この API は Lean が
  コンパイラ内部専用と明記しているため撤回し、安全な `Array.uget` を維持した

## Group 走査統合後

次に `hashi_group_match_h2` と `hashi_group_any_empty` が同じ制御バイトを
別々に読む点を解消し、`hashi_group_match_h2_and_empty` 一回に統合した。
通常ベンチの `find_miss` 中央値は 22.701 ns から 14.988 ns へ 34.0% 改善し、
`Std.HashMap` の 16.761 ns を 10.6% 上回った。`find_hit` は実質横ばい。

統合後の gprof では新しい Group 関数が self time の 36.4%で最大となった。
制御走査の呼び出し重複はなくなったため、次の候補はこの関数の SIMD 化または
Group 幅 16 化である。

## SSE2 化後

統合Group関数をx86_64でSSE2化した。通常ベンチの `find_miss` は
14.988 nsから11.563 nsへ22.9%改善し、`Std.HashMap` より32.4%高速になった。
`find_hit` も4.4%改善した。gprof のGroup self timeは0.52秒から0.21秒へ
59.6%減少した。

この結果、次は `matchingOffset?`、`findIndexWithHash?` の探査制御、および
`RawTable.get?` の値返却コストが主な調査対象になる。
