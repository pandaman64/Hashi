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
./scripts/profile.sh insert-reserved 262144 50
./scripts/profile.sh find-hit 262144 400 std
./scripts/profile.sh insert-grow 262144 50 std
```

引数は workload、要素数、反復数、実装（`hashi`または`std`、省略時は
`hashi`）。結果は
`.lake/profiles/<workload>/report.txt` に保存され、端末には flat profile の
先頭を表示する。Stdの結果は`.lake/profiles/std-<workload>/report.txt`。
サンプルが少ない場合は反復数を増やす。`gprof` の時間サンプル
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
- `insert-grow`（旧harness、完成マップ破棄込み）: RC 解放系が約 45%、
  `writeNew` 15.0%、再ハッシュ走査 6.5%。
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

## 挿入の単一pass化後

insertの既存キー探査と空き探査を統合した。通常ベンチの `insert_grow` は
249.544 nsから226.534 nsへ9.2%改善した。プロファイル上のGroup呼び出し総数は
58,109,300回から40,552,500回へ30.2%減少した。残る空き探査の大半は
再ハッシュ時の再挿入である。

## 挿入harness分離後

完成マップをタイマー停止後まで保持し、gprofでは`moncontrol`とopaqueなIO境界で
キー生成・reserve・マップ破棄中のサンプリングを止めた。

- `insert-grow`: 169.298 ns/op。`writeNew` 20.9%、再ハッシュ走査10.9%、
  RC cold pathと再帰deleterの合計は14.5%
- `insert-reserved`: 86.420 ns/op。`writeNew` 45.5%、RC cold pathは6.8%で、
  再帰deleterはサンプル上位から消えた

旧harnessの226.534 ns/opから破棄を外すと169.298 ns/opとなり、見かけ上25.3%
減った。この差は高速化ではなく、完成したキー・値配列の破棄コストである。
growがreservedの1.96倍であることから、挿入中の次の大きな差は再ハッシュと確保。
定常挿入自体の次の対象は`writeNew`である。

## Std.HashMapとの比較（追加最適化前）

同じキー列とサンプリング境界で両実装を計測した。gprof計装は関数境界の数によって
影響が変わるため、次の秒数はボトルネックの帰属に使い、通常性能の比には使わない。
性能比は比較ベンチのns/opを正とする。

| workload | Hashi sampled | Std sampled | 通常ベンチ Hashi / Std |
| --- | ---: | ---: | ---: |
| `insert-grow`（262,144×50） | 1.20 s | 0.53 s | 2.010× |
| `insert-reserved`（1,048,576×20） | 1.15 s | 0.44 s | 2.042× |
| `find-hit`（262,144×400） | 2.87 s | 2.68 s | 1.316× |
| `find-miss`（262,144×400） | 0.89 s | 2.02 s | 0.674× |

Hashiが遅い箇所は次のとおり。

- reserved insertでは`writeNew`だけで0.65秒（56.5%）。Stdのinsert全体は
  0.37秒（84.1%）だった。Hashiは各要素でkey配列、value配列、control byteの
  3個を別々に更新し、テーブルrecordとsize/growthLeftも作り直す
- growではHashiの`writeNew` 0.22秒に加え、再ハッシュ走査0.18秒、
  旧配列の再帰解放0.15秒、再挿入用の空き探索0.12秒がかかる。Stdはinsert
  0.23秒と、bucket chainを移す`AssocList.foldlM` 0.23秒にほぼ集約される
- hitではHashiの`RawTable.get?` 0.83秒、H2候補キー確認0.71秒、probe 0.23秒、
  Group比較0.20秒が分散して発生する。key確認後に別のvalue配列を読む二段階経路と、
  中間`Option USize`を含むallocation/freeがStdより多い
- missはHashiの方が速い。H2で候補を落とすため、104,857,600検索に対して実キー
  比較は3,428,800回だけ。Stdは全missでbucket chainのgetを実行する

したがって、挿入の第一候補は`writeNew`の3配列更新とrecord再構築の削減、
grow固有では再ハッシュ専用の直接配置経路である。hitの第一候補はindexの
`Option`を経由せず、候補一致時にvalueを直接返すlookup経路である。

## 比較結果に基づく最適化

growでは再ハッシュ先がEMPTYだけの新規テーブルであることを利用した。
`findAvailableWithHash?`の`Option USize`を経由せず、専用probeから
`writeRehashed`へ直接渡す。古いcontrol byteをH2 tagとして再利用し、配置前の
control再読込も省いた。

| grow profile | sampled time | `findAvailableWithHash?` calls |
| --- | ---: | ---: |
| 変更前 | 1.20 s | 22,938,300 |
| rehash専用経路 | 0.86 s | 900 |
| EMPTY/DELETED走査もSSE2化 | 0.81 s | 900 |

通常ベンチでは`insert_grow`の各runにおけるHashi/Std比の中央値が2.010倍から
約1.50倍へ縮んだ。reserved経路にはこの変更は適用されない。

lookupでは`findIndexWithHash? : Option USize`の後にvalue配列を読む二段階処理を
避け、H2候補キーが一致した時点でvalueを返す`getWithHash?`を追加した。

| lookup | 変更前 profile | 変更後 profile | 通常ベンチ Hashi / Std |
| --- | ---: | ---: | ---: |
| hit | 2.87 s | 2.11 s | 1.316× → 1.069× |
| miss | 0.89 s | 0.89 s | 0.674× → 0.610× |

hitの計装時間は26.5%減少した。missのgprofは0.01秒粒度では差が見えないが、
通常releaseベンチでは追加のindex `Option`を除いた効果が確認できる。

## home bucket hitのfast path

直接value経路の生成Cを確認すると、`matchingValue?`は候補の大半がoffset 0でも
boxed `Nat`のloop counter、範囲比較、shift、`USize`変換を実行していた。
control maskのbit 0が立つ場合はhome bucketをprobe内で直接読むようにした。

| 指標 | 変更前 | 変更後 |
| --- | ---: | ---: |
| `matchingValue?`再帰呼び出し | 104,886,800 | 25,993,600 |
| Hashi hit sampled time | 2.11 s | 2.06 s |
| Hashi hit ns/op | 31.060 | 26.617 |
| Hashi / Std hit | 1.059× | 0.943× |

同時に再計測したStdのsampled timeは2.88秒。gprof下の絶対比ではなく通常release
ベンチを性能判定に使っているが、再帰呼び出しが75.2%減ったことから、狙った
boxed counter経路を回避できたことも確認できる。

offset 1も同様に直接確認し、fallbackのboxed `Nat` loopをoffset 2から開始した。
再帰呼び出しはさらに25,993,600回から10,818,800回へ58.4%減少。通常ベンチの
hit中央値は26.617 ns/opから24.935 ns/opへ6.3%改善し、Stdの27.726 ns/opを
10.1%上回った。変更後のsampled timeはHashi 2.20秒、Std 2.61秒。
