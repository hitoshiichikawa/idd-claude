# 実装ノート（Issue #535）

## 概要

Promote Pipeline（`PROMOTE_PIPELINE_ENABLED=true`）が毎サイクル、リンク Issue ごとに
`gh issue view --json labels` を 2 回（`ready-for-review` 有無 + `staged-for-release` 有無
= 2×N 回/サイクル）発火していたラベル確認 API を、**1 回の `gh api graphql` 一括取得**へ
集約し、確認系 API 呼び出し回数を N 非依存の定数（サイクルあたり 1 回）に削減した。
外形契約（ラベル遷移結果・ログ書式・自己修復）は本変更前後で等価。

## 採用した実装機構と理由（仮案 B 採用）

requirements Open Questions の **仮案 B（複数 Issue の labels を 1 回の GraphQL alias クエリで
まとめ取得）** を採用した。理由:

- 取得対象を「当該サイクルの正確なリンク Issue 集合」（merged PR 50 件由来で有界）に限定でき、
  Req 1.5「固定件数上限によるサイレントな取りこぼしを起こさない」を構造的に満たす。仮案 C
  （ラベル別 `gh issue list --label` 突き合わせ）は closed Issue を含む一覧の `--limit`
  truncation リスクがあり、取りこぼし担保が追加で必要になるため不採用。
- closed Issue も `issue(number:)` alias で自然に取得でき、API 呼び出しは N によらず 1 回。
- 状態ファイル（仮案 D）は Req 1.3 の自己修復と両立しないため不採用（毎サイクル実ラベル状態
  から再導出）。

### 実装構造

- 新規ヘルパー `pp_fetch_issue_labels_map`（`local-watcher/bin/modules/promote-pipeline.sh`）:
  検証済みリンク Issue 番号を stdin から受け取り、GraphQL alias クエリ
  `i<idx>: issue(number:<N>){ number labels(first:100){nodes{name}} }` を 1 回の
  `gh api graphql` で発火。結果を Issue 番号 → 改行区切りラベル集合の in-memory マップ
  `PP_ISSUE_LABELS` に格納する。
- マップの可視性は **bash 動的スコープ**を利用。`pp_collect_merged_issues` が
  `local -A PP_ISSUE_LABELS` を per-cycle local として宣言し（module トップレベルに
  `declare -A` を置かない = 関数定義のみ規約遵守）、そこから呼ぶ `pp_issue_has_label` /
  `pp_remove_ready_for_review_if_present` が同一マップを参照する。
- N 非依存の核心: per-Issue の 2 判定（ready / staged）が同一マップエントリを参照するため、
  ラベル確認 API はサイクルあたり `gh api graphql` 1 回のみ（`promote-pipeline.sh:pp_fetch_issue_labels_map`）。

### 自己修復・結果等価をどう満たしたか

- **自己修復（Req 1.3/1.4/3.5）**: マップは毎サイクル `pp_collect_merged_issues` の先頭で
  作り直され、実ラベル状態から再導出する。状態ファイルで確認を省略しないため、人間が手動で
  `staged-for-release` を外した／`ready-for-review` を付け直した Issue は翌サイクルで
  再付与／再除去される（新規テスト Case 4 で観測）。
- **結果等価（Req 5.1/2/3）**: `pp_issue_has_label` の**シグネチャと既定挙動を保持**。マップ
  経由か view フォールバックかは判定手段の差のみで、真偽値の結果は同一。付与/除去の判定・
  ログ書式（`action=label-add` / `action=label-remove` / auto-label サマリ）は不変（Case 3 で
  現行書式を観測）。

## 既存テストの保全

`pp_issue_has_label` は **シグネチャ・既定挙動を無改変**で維持し、内部に in-memory マップ
参照分岐を追加した:

- マップが宣言されており当該 Issue の key が set → マップから判定（API 発火なし）。空ラベルでも
  key が set なら「持たない」と確定しフォールバックしない。
- マップ未宣言（`extract_function` で単体抽出した既存テスト文脈）または当該 Issue の key 未 set
  （graphql 失敗・部分欠落）→ 従来どおり `gh issue view --json labels` を 1 回呼ぶ。

これにより既存 `pp_remove_ready_for_review_test.sh` / `pp_extract_linked_issues_test.sh` /
`sn_callsite_promote_test.sh` を **無改変で全通過**（PASS 23/10/15）。key set 判定は nounset 安全な
`${arr[k]+set}` パラメータ展開、マップ宣言判定は動的スコープを尊重する `declare -p` を使用。

## 追加した呼び出し回数テスト（`local-watcher/test/pp_labels_map_test.sh` / 全 34 PASS）

- **Case 1/2（Req 5.2/1.1）**: N=3 と N=6 で `gh api graphql` 呼び出しが **同一の定数 1** で、
  `gh issue view` が **0 回**（N に比例しない）ことを `$GH_CALL_LOG` のコールカウンタで観測。
- **Case 3（Req 5.1/2/3）**: 未付与→付与ログ / 付与済→skip / ready 付き→除去ログ が現行書式で
  出ること、サマリ `staged-for-release-added=2, already-labeled-skipped=2` を観測。
- **Case 4（Req 1.3/1.4/3.5）**: 手動操作された Issue の自己修復（再付与・再除去）を観測。
- **Case 5（Req 4.1）**: graphql 失敗（rc=1）で WARN + per-Issue `gh issue view` フォールバックし
  結果継続を観測。
- **Case 6（Req 1.5/4.3/NFR 3.2）**: マップ構築（ready/staged 判定・空ラベル key set・null alias
  未 set）と、不正値 `-1` が alias 埋め込み前に除外され GraphQL query に `number:-1` が
  混入しないことを観測。
- **Case 7**: リンク Issue 0 件で graphql を発火しない（無駄打ち防止）ことを観測。

## GraphQL クエリの注入安全性（NFR 3.2）

- alias に埋め込む Issue 番号は埋め込み直前に `^[0-9]+$` を満たすもののみ使用（`pp_fetch_issue_labels_map`
  の stdin 読み取りループで再検証、不一致はスキップ）。GraphQL `number:` は Int なので整数のみで
  注入面は塞げるが検証を省いていない（Case 6 で `-1` 除外を担保）。
- owner / name は `$REPO` 由来（信頼値）だが `-f owner=... -f name=...` の GraphQL 変数渡しで
  query 文字列へ inline 展開しない。
- ラベル区切りは ASCII Unit Separator（0x1f、GitHub ラベル名に出現しない制御文字）を jq
  `join("")` で使用し、`@tsv`（US を非エスケープ）→ bash で改行へ変換。`grep -qxF --`
  で行全体・固定文字列一致（部分一致・フラグ注入を防止）。

## AC トレーサビリティ

| 要件 | 担保テスト / 実装箇所 |
|---|---|
| Req 1.1（N 非依存の定数上界） | pp_labels_map_test Case 1/2（graphql=1 定数） |
| Req 1.2（1 サイクル内で重複取得しない） | pp_labels_map_test Case 3（view=0 / 2 判定が同一マップ参照） |
| Req 1.3/1.4（自己修復・再付与） | pp_labels_map_test Case 4 |
| Req 1.5（取りこぼしなし） | pp_labels_map_test Case 6（全 alias 反映）/ Case 2（N=6 全件） |
| Req 2.1/2.2/2.3（付与・skip・付与ログ） | pp_labels_map_test Case 3 / 既存 pp_remove_ready_for_review_test |
| Req 2.4（付与失敗 WARN） | 既存 pp_remove_ready_for_review_test Case 5/7（fail-continue 経路）※付与失敗経路は実装不変 |
| Req 2.5（auto-label サマリ書式） | pp_labels_map_test Case 1/2/3 |
| Req 3.1/3.2/3.3（ready 除去・skip・除去ログ） | pp_labels_map_test Case 3 / 既存 pp_remove_ready_for_review_test Case 1〜4 |
| Req 3.4（除去失敗 WARN） | 既存 pp_remove_ready_for_review_test Case 5/7 |
| Req 3.5（ready 再除去 自己修復） | pp_labels_map_test Case 4 |
| Req 4.1（取得失敗 WARN + fail-continue） | pp_labels_map_test Case 5 |
| Req 4.2（gh pr list 失敗で no-op） | 実装不変（`pp_collect_merged_issues` 冒頭の既存 WARN + return） |
| Req 4.3/NFR 3.2（Issue 番号 `^[0-9]+$` 再検証） | pp_labels_map_test Case 6 |
| Req 4.4/NFR 1.2（gate OFF で API ゼロ） | 実装不変（`process_promote_pipeline` の `!= true` 早期 return）。#535 の graphql は `pp_collect_merged_issues` 内でのみ発火し、gate 通過後にしか到達しない。既存 `sn_callsite_promote_test` 等で pipeline gate 挙動を回帰確認 |
| Req 5.1（結果等価） | pp_labels_map_test Case 3 + 既存 3 テスト無改変通過 |
| Req 5.2（N 非依存をトレース観測） | pp_labels_map_test Case 1/2 |
| Req 5.3（既存 3 テスト通過） | pp_remove_ready_for_review(23) / pp_extract_linked_issues(10) / sn_callsite_promote(15) |
| NFR 1.1/1.3（後方互換・新規 gate なし） | env var/ラベル/exit code/ログ出力先 不変、opt-in gate 追加なし |
| NFR 2.1（2×N → 定数） | pp_labels_map_test Case 1/2（graphql=1） |
| NFR 2.2（--limit 50 不変） | `pp_collect_merged_issues` の gh pr list `--limit 50` 不変 |
| NFR 5.1（bash -n / shellcheck） | 下記「実行した検証」参照 |

## 実行した検証（結果サマリ）

- `bash -n local-watcher/bin/modules/promote-pipeline.sh` → OK（構文エラー 0 / NFR 5.1）
- `shellcheck local-watcher/bin/modules/promote-pipeline.sh` → clean（警告増加 0。GraphQL
  変数の意図的単一引用符に局所 `# shellcheck disable=SC2016` を付与、理由コメント併記）
- `shellcheck local-watcher/test/pp_labels_map_test.sh` → clean
- `bash local-watcher/test/pp_remove_ready_for_review_test.sh` → PASS 23 / FAIL 0
- `bash local-watcher/test/pp_extract_linked_issues_test.sh` → PASS 10 / FAIL 0
- `bash local-watcher/test/sn_callsite_promote_test.sh` → PASS 15 / FAIL 0
- `bash local-watcher/test/pp_labels_map_test.sh`（新規）→ PASS 34 / FAIL 0
- 関連 po_/sn_ テスト群も全 PASS（回帰なし）

## 二重管理・README

- `promote-pipeline.sh` は `local-watcher/bin/modules/` の単一管理（`repo-template/` に複製なし）。
  agents/rules の byte 一致同期対象外。
- README「Phase B: Promote Pipeline 補助フロー」節に「ラベル確認 API の N 非依存化（#535）」を
  1 段落追記（外形契約不変のため差分のみ）。状態ファイルは導入していない（自己修復維持）。

## 確認事項

なし。requirements.md の Open Questions は仮案 B 採用・自己修復維持（Req 1.3 で確定済み）で
解決済み。design.md / tasks.md は本 Issue には存在せず、推奨実装方針（Architect 不在）を
踏襲した。

STATUS: complete
