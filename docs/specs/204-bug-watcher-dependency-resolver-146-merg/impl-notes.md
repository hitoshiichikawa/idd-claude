# 実装ノート (#204)

## 概要

Dependency Resolver（#146）の `dr_resolve_one` が merge 済み依存を `closed unmerged` と
永久誤判定する false-block バグを是正し、あわせて `dr_extract_deps` がコードフェンス・
引用ブロック内の依存マーカーを誤抽出する同根の堅牢性問題（Req 4）も修正した。

design.md / tasks.md は本 Issue には存在しない（Architect フェーズ未経由）。requirements.md
を入力として直接実装した。

## バグの根因

`gh issue view <N> --json closedByPullRequestsReferences` が返す PR ノードには
`merged` フィールドが**存在しない**（`id` / `number` / `repository` / `url` のみ）。
旧 `dr_resolve_one` は `jq '[.closedByPullRequestsReferences[]? | select(.merged == true)] | length'`
で集計していたため、merge 済み PR でも常に 0 件 → `closed unmerged` を返し、merge 済み
依存に対して永久 `blocked` 再付与が起きていた（実害: #187 が merge 済み #177/#180/#181 に
永久ブロック）。

## 変更点

### Req 1, 2, 3（`dr_resolve_one` の merge 判定是正）

- 取得経路を `gh issue view --json` から **GraphQL** に変更。`check_existing_impl_pr`
  （L4979-）に確立済みの `closedByPullRequestsReferences(first:20, includeClosedPrs:true){ nodes { state } }`
  パターンを踏襲し、PR ノードの `state == "MERGED"` を 1 件以上検出すれば `resolved` と判定。
- `gh api graphql` 呼び出しを `dr_gh_graphql_closed_by` 関数に切り出し、回帰テストが
  GraphQL レスポンスを mock 注入できる薄い indirection とした（関数の差し替えで実 API を
  叩かずに判定ロジックを検証できる）。
- 安全側挙動（Req 2.1, 2.2）: gh 非 0 rc / GraphQL HTTP200 errors / jq parse 失敗 /
  issue.state が null・空 / 集計結果が非数値 / 未知 state → すべて `api error`。
- `$REPO` を `owner` / `repo` に分解（L4962-4969 のパターン踏襲）。owner/repo 形式でない
  場合も `api error`。
- timeout は既存 `DRR_GH_TIMEOUT`（default `${MERGE_QUEUE_GIT_TIMEOUT:-60}`）を流用。
  **新規 env var は導入していない**（Req 3.5 / NFR 3.1）。
- verdict 語彙（`resolved` / `open` / `closed unmerged` / `api error`）・ラベル契約
  （`blocked` 付与 / `claude-claimed` 除去）・ログ書式（`dr_log` / `dr_warn`）・env var 名は
  すべて不変（Req 3.1〜3.5）。`dr_resolve_one` は stdout で verdict 1 行を返す契約も維持。

### Req 4（`dr_extract_deps` の誤検出防止）

- awk による markdown 前処理を追加。(a) ` ``` ` / `~~~` で開閉されるコードフェンス内の行、
  (b) 行頭（任意個の空白許容）が `>` で始まる引用ブロック行を、依存マーカーマッチの前に
  除去する。実依存宣言行のみから `#N` を抽出する。
- フェンスマーカー行自体（言語タグ付き ` ```bash ` 等を含む）も抽出対象外。フェンスは
  開→閉のトグルで管理。
- 重複排除・決定的順序（`sort -u -n` による数値昇順 uniq）は維持。関数の純粋性
  （副作用なし・stdout に番号集合）も不変。

## requirement ID → テスト対応表

回帰テスト: `docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh`
（実 API を叩かず `dr_gh_graphql_closed_by` を stub 差し替え + dr_* 関数ブロックを awk 抽出して source）。

| Req ID | 担保するテストケース |
|---|---|
| 1.1 | `Req1.1 CLOSED+MERGED PR` → resolved / `Req1.1 CLOSED+(CLOSED,MERGED) 混在` → resolved |
| 1.2 | `Req1.2 CLOSED+CLOSED PR(未merge)` → closed unmerged |
| 1.3 | `Req1.3 CLOSED+PR 0件` → closed unmerged |
| 1.4 | `Req1.4 OPEN issue` → open |
| 1.5 | `Req5.4 旧 .merged 式は誤って 0 件` / `Req5.4 新 .state 式は正しく 1 件`（観測経路是正の固定） |
| 2.1 | `Req2.1 gh 失敗 rc!=0` / `Req2.1 GraphQL errors` → api error |
| 2.2 | `Req2.2 issue=null 想定外構造` / `Req2.2 壊れた JSON` / `未知の issue state` → api error |
| 2.3 / 2.4 | caller `dr_check_dependencies`（L6063-）の既存ロジックで担保。本修正で挙動不変（unresolved/api_error が 1 件でも block、全 resolved で続行）。回帰は verdict 語彙の不変性で間接担保 |
| 3.1 | verdict 語彙 4 種に限定（テストの assert 値が 4 語彙のみ） |
| 3.2 / 3.3 | `dr_apply_block` / caller の冪等ガードは本修正で未変更（diff なし）。既存挙動保全 |
| 3.4 | `dr_log` / `dr_warn` 書式不変（関数本体未変更）。テストでは副作用ログを stub で捨てる |
| 3.5 | 新規 env var を導入していないこと（grep で `DRR_GH_TIMEOUT` 流用を確認） |
| 4.1 | `Req4.1 実依存行から抽出` |
| 4.2 | `Req4.2 コードフェンス内は除外` / `Req4.2 フェンスのみ→空` / `Req4.2 チルダフェンス除外` |
| 4.3 | `Req4.3 引用ブロック除外` / `Req4.3 インデント引用除外` |
| 4.4 | `Req4.4 重複排除+昇順` |
| 4.5 | `Req4.5 依存なし→空` / `空入力→空` |
| 5.1 | `Req1.1 CLOSED+MERGED PR` |
| 5.2 | `Req1.2 CLOSED+CLOSED PR(未merge)` |
| 5.3 | `Req1.4 OPEN issue` |
| 5.4 | `Req5.4 旧 .merged 式は誤って 0 件` → `Req5.4 新 .state 式は正しく 1 件`（Red→Green を同一 fixture で固定） |

NFR:
- NFR 1.1（依存記法 0 件で副作用 0）: `dr_check_dependencies` 冒頭の `skip_no_deps` 早期 return は
  未変更。`dr_extract_deps` が空を返せば gh 呼び出し 0 回（テスト `Req4.5` / `空入力→空` で抽出が空になることを担保）。
- NFR 1.2（`needs-decisions` 不変更）: `dr_apply_block` 未変更で担保。
- NFR 2.1 / 2.2（構造化ログ / 警告ログ）: `dr_log` / `dr_warn` 書式不変。
- NFR 3.1（API 呼び出し線形）: `dr_resolve_one` は依存 1 件あたり `gh api graphql` を 1 回のみ呼ぶ（GraphQL 1 リクエストで state + PR nodes を取得）。

## 実装上の判断・確認事項

- **Req 4 を本修正に含めた**: requirements.md Open Questions の推奨どおり本 PR に含めた。
  merge 判定バグ（Req 1〜3）と誤抽出（Req 4）は「依存解決の堅牢性不足による false-block」
  という同根の症状で、awk 前処理の追加は小規模・純粋関数の契約を崩さず、別 Issue 分離が
  必要なほどの実装複雑度には至らなかったため。分離提案はしない。
- **検証スクリプトの source 方式**: watcher 本体は末尾に main 実行コード（`_dispatcher_run`）を
  持ち `BASH_SOURCE` ガードが無いため直接 source できない。テストは `dr_log()` 〜
  `dr_check_dependencies()` 末尾までの関数定義ブロックを awk で抽出し、mock スタブと一緒に
  source する方式を採った。この marker（`dr_log() {` 開始 / `dr_check_dependencies` 末尾 `}`）
  は watcher のリファクタでずれ得るため、テスト側に「抽出失敗時 FATAL」ガードを入れてある。
- **GraphQL クエリの `first: 20`**: `check_existing_impl_pr` と同値。1 Issue を閉じる PR が
  20 件を超えるケースは idd-claude 運用では非現実的なため十分なマージン。
- **caller `dr_check_dependencies` は未変更**: Req 2.3 / 2.4 / 3.2 / 3.3 のブロック確定・
  冪等 skip ロジックは本修正で触っていない（diff なし）。verdict 語彙が不変なので caller の
  case 文も影響を受けない。

## 派生タスク候補（次 Issue 化の検討）

- requirements.md の関数ヘッダコメントが `Req 1.1〜1.5, 1.7` のように #146 当時の旧 ID を
  参照している箇所が残る（本修正で触れた範囲は #204 ID に更新したが、`dr_format_unresolved_comment`
  等は #146 ID のまま）。ドキュメント整合の軽微な追従。本修正のスコープ外。

## 検証結果

- 回帰テスト: `bash docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh`
  → 全 21 ケース pass（exit 0）。
- `shellcheck local-watcher/bin/issue-watcher.sh` → 警告は 10 件すべて既存の SC2317（info,
  間接呼び出しロガーの unreachable 誤検知）のみ。main ベースラインと同数で**新規警告ゼロ**。
- `shellcheck docs/specs/204-.../test-dependency-resolver.sh` → clean（exit 0）。
- `bash -n local-watcher/bin/issue-watcher.sh` → syntax OK。

## コミット

- `d13a3db` fix(watcher): dr_resolve_one が merged 依存を closed unmerged と誤判定する不具合を修正（Req 1/2/3）
- `ef560bf` fix(watcher): dr_extract_deps がコードフェンス/引用内の依存マーカーを誤抽出する不具合を修正（Req 4）
- `67a33c2` test(watcher): Dependency Resolver の merge 判定 / 依存抽出の回帰テストを追加（Req 5）

STATUS: complete
