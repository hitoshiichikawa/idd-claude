# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-146-impl-feat-harness-pm-phase-issue-issue-merge
- HEAD commit: ad3ff0a1f5697f5c6ad9476f7887a8833204f652
- Compared to: main..HEAD
- 実装 commit: f7b4f91, 03b578a, f748c3e, d2889fb, 30fdc9c, f234b93, 607588e（+ 進捗マーカー 7 件）
- Feature Flag Protocol 採否: opt-out（CLAUDE.md 節なし / fallback opt-out / NFR 1.1 互換）→ 通常 3 カテゴリ判定のみ適用

## Verified Requirements

### Requirement 1: 依存 Issue 番号の抽出

- 1.1 — `dr_extract_deps`（`local-watcher/bin/issue-watcher.sh` line 10417 周辺）が `grep -E '(Depends on:|前提依存:|Blocked by:)'` で canonical を検出。再現テストで `Depends on: #12 #34` → `12\n34` を確認
- 1.2 — 同関数の `前提依存:` 行検出。再現テストで `前提依存: #100` → `100` を確認
- 1.3 — 同関数の `Blocked by:` 行検出。再現テストで `Blocked by: #200` → `200` を確認
- 1.4 — `grep -oE '#[0-9]+'` で行内の番号を全列挙。再現テストでスペース区切り（Test 1）/ カンマ区切り（Test 7 `#1, #2, #3` → `1\n2\n3`）の双方を確認
- 1.5 — `sort -u -n` による uniq + 数値昇順。再現テストで `Depends on: #1\nBlocked by: #1 #2` → `1\n2`（重複排除済）
- 1.6 — `dr_check_dependencies` 冒頭で空集合判定 → `verdict=skip_no_deps` ログ + return 0 のパスを確認
- 1.7 — canonical `Depends on:` + alias `前提依存:` / `Blocked by:` の 3 種が `.claude/rules/issue-dependency.md` のキャノニカル + alias 表と完全一致

### Requirement 2: 依存 Issue の merge 状態判定

- 2.1 — `dr_resolve_one` が `gh issue view "$dep_num" --repo "$REPO" --json state,closedByPullRequestsReferences` を実行（line 10480 周辺）
- 2.2 — `jq '[.closedByPullRequestsReferences[]? | select(.merged == true)] | length'` で boolean true 比較を行い、結果 >0 → `resolved`。design 指定どおりの boolean true 比較
- 2.3 — `state == OPEN` → `echo "open"` の case 分岐を確認
- 2.4 — CLOSED かつ merged_count == 0 → `echo "closed unmerged"` を確認
- 2.5 — gh 失敗 / jq parse 失敗 / 未知 state を `api error` にマップ。`dr_warn` でログ
- 2.6 — `dr_check_dependencies` 内の集計ループで unresolved/api_error 行が 1 件でもあれば `dr_apply_block` + return 1 を確認

### Requirement 3: ブロック検出時のラベル付与とエスカレーション

- 3.1 — `dr_apply_block` 内 `gh issue edit ... --add-label "$LABEL_BLOCKED"`（line 10560 周辺）
- 3.2 — `gh issue comment ... --body "$body"` でコメント 1 件投稿。重複投稿は呼び出し元冪等性ガードで防止
- 3.3 — 単一 `gh issue edit --remove-label "$LABEL_CLAIMED" --add-label "$LABEL_BLOCKED"` で原子的に付け替え（Task 3 仕様どおり）
- 3.4 — `dr_check_dependencies` 冒頭の `if printf '%s\n' "$labels" | grep -qx "$LABEL_BLOCKED"; then` で既付与時は再付与 skip + return 1
- 3.5 — `_slot_run_issue` line 10840 で `if ! dr_check_dependencies ...; then slot_log ... return 0; fi` により Triage 起動を skip
- 3.6 — `dr_format_unresolved_comment` が `- #N (区分)` 形式で列挙（open / closed unmerged / api error）

### Requirement 4: Dispatcher による blocked Issue の pickup 除外

- 4.1 — `_dispatcher_run` line 11243 の `gh issue list --search` 末尾に `-label:\"$LABEL_BLOCKED\"` を追加
- 4.2 — 除外クエリのみが pickup 判定の正本。`blocked` 手動除去で次サイクルに再合流する構造
- 4.3 — 既存除外ラベル 9 件の順序・値はそのままで `BLOCKED` を末尾に append（NFR 1.3 / NFR 1.2 互換維持）

### Requirement 5: 検出パターン非存在時の後方互換

- 5.1 — `dr_extract_deps` が空 stdout → `dr_check_dependencies` で `verdict=skip_no_deps` ログ後 return 0
- 5.2 — skip 経路では `dr_apply_block` を呼ばず副作用ゼロ
- 5.3 — `dr_extract_deps` は gh API 呼び出しゼロ・ローカル regex のみで完了

### Requirement 6: 実行ログ記録

- 6.1 — `dr_check_dependencies` 内で `dr_log "issue=#${issue_num} extracted=... resolved=... unresolved=... api_errors=... verdict=..."` を全ケースで 1 行出力。design.md「Log Schema」一致
- 6.2 — `dr_resolve_one` 内で gh 失敗 / jq parse 失敗時に `dr_warn` 出力
- 6.3 — `dr_log` / `dr_warn` / `dr_error` は既存 `mq_log` / `pi_log` 系と同書式（stdout / stderr 経路）で `LOG_DIR` 配下に乗る

### Requirement 7: `blocked` ラベル定義の配布

- 7.1 — `.github/scripts/idd-claude-labels.sh` line 78 に `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能"` を追加
- 7.2 — description に「依存 Issue 未 merge により auto-dev 進行不能」を含む
- 7.3 — self-hosting 用に `【Issue 用】` prefix を採用（既存規約整合）
- 7.4 / 7.5 — 既存 `gh label create ... 2>/dev/null || gh label edit ...` ロジックがそのまま発火（NFR 3.2）
- 7.6 — `repo-template/.github/scripts/idd-claude-labels.sh` line 75 にも同じ `"blocked|b60205|【Issue 用】 ..."` を追加

### Requirement 8: README.md ドキュメント整備

- 8.1 — README.md 行 461 「作成されるラベル」表に `blocked` 行追加
- 8.2 — 行 899 「ラベル状態遷移まとめ」表に `blocked` 行追加 + 行 913 ポーリングクエリに `-label:blocked` 追加
- 8.3 — 行 932 周辺で canonical / alias 3 種への参照と `.claude/rules/issue-dependency.md` リンクを記載
- 8.4 — 解消手順「依存先を merge → blocked 手動除去 → 次 cron tick で再評価」を明文化
- 8.5 — `blocked` と `needs-decisions` の意味的差分（1 行）を行 939 周辺に明示
- 8.6 — QUICK-HOWTO.md 行 74 「作成されるラベル」インライン列挙に `blocked` を追記

### Requirement 9: `needs-decisions` との意味的分離

- 9.1 — `dr_apply_block` 内では `--add-label "$LABEL_BLOCKED"` のみで `needs-decisions` には触れない
- 9.2 — `dr_format_unresolved_comment` のテンプレが「判断を委ねる」「決定事項」等の needs-decisions 用語彙を含まず、依存未解決専用文面
- 9.3 — `_dispatcher_run --search` で `-label:"needs-decisions"` と `-label:"blocked"` が並列指定され、状態遷移は独立
- 9.4 — README で両ラベルを別行で列挙 + 将来統合しない方針を明示

### Non-Functional Requirements

- NFR 1.1 — 依存記法非搭載 Issue では `dr_log` 1 行のみ。gh API・ラベル変更・コメント投稿ゼロ
- NFR 1.2 — 既存ラベル定義の name / color / description / 順序は不変（diff 確認）
- NFR 1.3 — dispatcher 既存除外条件 9 件の順序・値不変 + `BLOCKED` 末尾追加
- NFR 1.4 — markdown コードフェンス内・引用ブロック内の誤検出は運用許容として明文化（design.md / コード comment）
- NFR 2.1 — 構造化ログ `dr: issue=#N extracted=... verdict=...` で grep 集計可能
- NFR 2.2 — 既存 stdout/tee 経路に乗る
- NFR 3.1 — `dr_check_dependencies` 冒頭の冪等性ガードで N 回再実行に対し付与数 1 / コメント数 1 に収束
- NFR 3.2 — labels.sh の冪等性は既存ロジックがそのまま保持
- NFR 4.1 — 通常 1〜3 件の依存で `gh issue view` 数回 = 数秒、cron tick 内に収まる
- NFR 4.2 — rate limit / API 失敗 → `api error` → unresolved 集合に積む → `blocked` 確定（安全側）

### Out of Scope 遵守確認

- impl-resume 経路（`HAS_EXISTING_SPEC=true`）では `dr_check_dependencies` 未呼び出し（`_slot_run_issue` line 10824〜 の if/elif 構造で `else` ブランチにのみ Dependency Resolver Gate を配置）→ 在 in-flight Issue への retrofit 回避
- skip-triage ラベル経路でも `elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"` ブランチで未呼び出し → 既存挙動完全維持
- auto-unblock（依存解消後の自動 blocked 除去）は実装に含まれず（README にも提供しない旨明示）
- 循環依存検出は実装されず（未解決 1 件以上で block 確定する設計）
- 逆方向 `Blocks:` 記法は検出対象に含まれず（grep パターンに含まれない）
- クロスリポジトリ参照（`owner/repo#N`）は対象外（`#[0-9]+` のみ抽出）

## Findings

なし

## Summary

Issue #146 の 7 タスク（impl 7 commit + 進捗マーカー 7 commit）はすべて Developer により完了済みで、
要件定義 9 件 + NFR 4 件のすべての numeric AC が実装またはコード読みでカバーされていることを確認した。
shellcheck は既存 SC2317 info / SC2012 info のみで新規警告は dr_error の SC2317 info（既存ヘルパ
パターンと同等の info で reject 対象外）に限定。boundary 逸脱なし、Out of Scope の境界も遵守。
構造化ログ・冪等性ガード・rate limit 安全側挙動・既存除外ラベル順序維持・両 labels.sh 同名同
description・README/QUICK-HOWTO 整備すべて design.md 指定どおり。実 gh API 副作用を伴う E2E は
本 worktree では未実施だが、CLAUDE.md「テスト・検証」節（bash + 手動スモーク主体）と impl-notes.md
の単体スモーク + コード読み検証で代替されており、reviewer 側で再現した dr_extract_deps 7 ケースも
すべて期待出力どおり。3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）いずれにも該当する
問題は検出されなかった。

RESULT: approve
