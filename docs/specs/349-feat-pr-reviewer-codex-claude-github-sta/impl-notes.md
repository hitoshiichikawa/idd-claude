# 実装ノート: feat(pr-reviewer): codex/claude レビュー結果を GitHub status check として publish (#349)

## Implementation Notes

### 採用方針

- 既存 `modules/pr-reviewer.sh` に `pr_` prefix で 4 関数追加（散逸防止 / 機能追加ガイドライン 1, 2）
- `PR_REVIEWER_STATUS_CHECK_ENABLED` は既存「opt-in gate と後方互換」規約（#348 と同形）で
  `=true` 厳密一致以外はすべて `false` に正規化（Req 1.3 / NFR 1.1）
- AND 二重 opt-in は `pr_status_check_enabled` ヘルパーに集約（codex 経路 / claude 経路の双方で使う共通評価点）
- claude-review 経路は本体 `issue-watcher.sh` の `publish_claude_review_status` から
  `parse_review_result` + `gh pr list --head $BRANCH` + `pr_publish_claude_status` を順に呼ぶ
  構成（PR 番号 / head sha は呼び出し時点で最新の状態を採用 / Req 4.1）

### 重要な判断

- **古い head sha への明示削除 API は呼ばない**（Out of Scope 明記）。GitHub の
  latest-wins-per-(sha,context) 仕様に依存し、head sha 更新時は新 sha に対して publish して
  status を「移動」させる。これにより API 呼び出し量を最小化（NFR 2.1）し、再 POST 競合や
  古い sha 検索のロジックを増やさない
- **gate OFF 時の suppression ログは cycle あたり最大 1 行**（Req 7.2）。
  `PR_STATUS_GATE_SUPPRESS_LOGGED` フラグでサイクル内重複を抑止。`FULL_AUTO_ENABLED` OFF 起因の
  suppression は #348 既存 suppression ログに委ね、本機能では `PR_REVIEWER_STATUS_CHECK_ENABLED`
  OFF 起因のみ記録（Req 7.3 / 既存ログ量肥大の予防）
- **per-task 経路でも publish を発火**: 本要件は「review-notes.md commit 時点」が canonical
  なトリガと定義。per-task ループでも各 task 単位で review-notes.md は commit / push されるため、
  per-task 経路の round=1 / round=2 / round=3 approve / reject すべてに publish を配線
  （single-issue 経路と対称）
- **publish 失敗はパイプライン継続**: Req 5.3 に従い `|| true` で WARN を残しつつ後続を継続。
  status が出ない場合でも運用者はコメントから verdict を確認できる（Req 5.5）
- **未信頼入力検証**: sha は `^[0-9a-f]{40}$`、PR 番号は `^[0-9]+$` で使用直前に検証
  （NFR 1.3 / 1.4）。検証失敗時は publish せず WARN + rc=2 を返す（path injection 予防）
- **description は 72 文字以内に短縮**（要件 AC 2.3 / 3.3）。GitHub 仕様は 140 文字だが、
  運用要件で 72 文字を上限とする保守的しきい値を採用

### 残存課題

- なし（要件 numeric ID すべてに対応するテストを追加。requirements.md の Open Questions も「なし」と
  確認済み）
- 将来拡張余地: ① Check Run UI 化（GitHub App 必須）、② antigravity の VERDICT 出力 schema
  確定後の `pr_publish_codex_status` 内 JSON 抽出ロジック洗練、③ branch protection 自動設定
  bot（人間運用領分のため今回は対象外）

## 変更ファイル一覧

| Path | 概要 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | Config 宣言（`PR_REVIEWER_STATUS_CHECK_ENABLED`、正規化）、Reviewer 完了直後の `publish_claude_review_status` 配線（single / per-task 経路 round=1/2/3 approve/reject）、`publish_claude_review_status` ヘルパー追加 |
| `local-watcher/bin/modules/pr-reviewer.sh` | `pr_status_check_enabled` / `pr_publish_commit_status` / `pr_publish_codex_status` / `pr_publish_claude_status` 追加、`pr_run_review_for_pr` 末尾に `pr_publish_codex_status` 配線 |
| `local-watcher/test/pr_publish_commit_status_test.sh` | 新規テスト（53 assertion / 4 系統: codex/claude × success/failure/gate off/publish failure を網羅） |
| `README.md` | オプション機能一覧の `PR_REVIEWER_STATUS_CHECK_ENABLED` 行追加、`## PR Reviewer Commit Status Publishing (#349)` 詳細節追加（AND-semantics / context 名 / branch protection 設定手順） |

## 新関数一覧

| 関数 | Prefix | 配置 | 責務 | 主要 AC |
|---|---|---|---|---|
| `pr_status_check_enabled` | `pr_` | `modules/pr-reviewer.sh` | AND 二重 opt-in（`PR_REVIEWER_STATUS_CHECK_ENABLED` AND `FULL_AUTO_ENABLED`）評価 | 1.2, 1.4, 6.1 |
| `pr_publish_commit_status` | `pr_` | `modules/pr-reviewer.sh` | GitHub Commit Status API 低レベル呼び出し（gate / 入力検証 / API call / WARN） | 2.x, 3.x, 5.x, 7.x, NFR 1.x |
| `pr_publish_codex_status` | `pr_` | `modules/pr-reviewer.sh` | codex / antigravity の VERDICT → state 解決 + publish | 2.1, 2.2, 2.5 |
| `pr_publish_claude_status` | `pr_` | `modules/pr-reviewer.sh` | Claude Reviewer の RESULT → state 解決 + publish | 3.1, 3.2, 3.3 |
| `publish_claude_review_status` | — | `issue-watcher.sh`（本体） | Reviewer ステージ完了直後の orchestration（parse / PR lookup / blob URL 組立 / publish 呼び出し） | 3.1〜3.5, 4.1, 7.x |

## テスト戦略

- `extract_function` イディオムで対象 4 関数を `modules/pr-reviewer.sh` から抽出して eval
- `gh` / `pr_log` / `pr_warn` / `pr_error` / `timeout` を関数 stub に置き換え、引数 / 出力 /
  記録ファイルを観測
- `GH_NEXT_RC` 環境変数で `gh` stub の戻り値を制御し publish failure を再現
- 53 assertion で以下を網羅:
  - Section 1（AND gate）: 両 OFF / 片方 OFF / 両 ON / 値正規化 7 種
  - Section 2（pr_publish_commit_status）: gate OFF / success / failure / 不正 sha / 不正 PR 番号 / API 失敗 / description 切り詰め
  - Section 3（pr_publish_codex_status）: approve / needs-iteration / gate OFF
  - Section 4（pr_publish_claude_status）: approve / reject / 不正 result / gate OFF / API 失敗

## 検証結果

| Check | コマンド | 結果 |
|---|---|---|
| `bash -n` | `bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh` | OK |
| `shellcheck` | `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh` | 警告ゼロ |
| 新規テスト | `bash local-watcher/test/pr_publish_commit_status_test.sh` | PASS=53 FAIL=0 |
| 全テスト | `for t in local-watcher/test/*_test.sh; do bash "$t"; done` | 全 27 ファイル PASS |
| 二重管理同期 | `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` | 空（差分なし） |

## AC Traceability

| AC | 担保するテスト / 配線 |
|---|---|
| 1.1 / 1.3 | `pr_status_check_enabled` Section 1（値正規化 7 種 / 既定 false） |
| 1.2 / 1.4 | `pr_status_check_enabled` Section 1（両 gate ON のみ enabled） |
| 1.5 | gate OFF テスト 全 case（gh 呼び出しゼロ / コメント挙動非干渉） |
| 2.1 | `pr_publish_codex_status` Section 3 Case A（VERDICT approve → success） |
| 2.2 | `pr_publish_codex_status` Section 3 Case B（VERDICT needs-iteration → failure） |
| 2.3 | Section 2 Case B / C（description 検査） + Case G（72 文字短縮） |
| 2.4 | Section 2 Case B（target_url=PR URL）+ Case C（target_url 空時の処理） |
| 2.5 | Section 3 Case B（antigravity でも context=codex-review 共有） |
| 3.1 / 3.2 | `pr_publish_claude_status` Section 4 Case A / B（approve→success / reject→failure） |
| 3.3 | Section 4 Case A / B（description=claude: ...） |
| 3.4 | Section 4 Case A（target_url に blob URL）+ `publish_claude_review_status`（issue-watcher.sh）で組立 |
| 3.5 | Section 4 Case C（不正 result → rc=4 + WARN）+ `publish_claude_review_status` の parse_rc≠0 分岐 |
| 4.1 / 4.2 / 4.3 | `publish_claude_review_status` が呼び出し時点の head sha を `gh pr list --head` で取得 + GitHub latest-wins 仕様に依存（Out of Scope の明示削除なし） |
| 5.1 / 5.4 | Section 2 Case F / Section 4 Case E（API 失敗 → WARN + rc=3） |
| 5.2 | Case F の WARN payload（PR / sha / context / state / 終了コード） |
| 5.3 / 5.5 | call site で `|| true` を付け publish 失敗時もパイプライン継続。コメント投稿は publish より前に完了 |
| 6.1 / 6.2 / 6.3 | gate OFF テスト全 case + 既存挙動を変更していない（NFR 3.2 / 3.3） |
| 7.1 | Section 2 Case B（成功 log 1 行） |
| 7.2 | Section 2 Case A（suppression ログ 1 回目のみ） |
| 7.3 | `pr_publish_commit_status` 実装で `FULL_AUTO_ENABLED` OFF 単独起因はログを出さない |
| NFR 1.1 / 1.2 | gate OFF 時の gh 呼び出しゼロを全 case で確認 + `gh api -X POST` の URL 引数は事前検証済 sha / repo のみ |
| NFR 1.3 / 1.4 | Section 2 Case D / E（sha / PR 番号の不正値検出） |
| NFR 2.1 | 1 publish = 1 gh api 呼び出し（cycle 内追加ループなし） |
| NFR 3.1 | gate 未設定環境で gh 呼び出しゼロ（全 gate OFF case） |
| NFR 3.2 / 3.3 | 既存 env var / 関数契約を変更していない（diff で確認） |
| NFR 4.1 / 4.3 | README にオプション機能一覧追加 + 詳細節（context 名 / AND-semantics / branch protection 設定手順） |
| NFR 4.2 | `repo-template/` 配下にあるべきファイルは現状 `.claude/{agents,rules}` のみで diff -r 空。本リポジトリ内 `local-watcher/` は単一の真実源 |
| NFR 5.1 | `shellcheck` / `bash -n` 警告ゼロ |
| NFR 5.2 | 53 assertion（4 系統 codex/claude × success/failure/gate off/publish failure 網羅） |

## 確認事項

- なし（実装途中で要件 / 設計との矛盾は発生せず。Open Questions も requirements.md 上「なし」と明示済み）

STATUS: complete
