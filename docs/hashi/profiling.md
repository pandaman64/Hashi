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
./scripts/profile.sh insert-grow 262144 20
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
